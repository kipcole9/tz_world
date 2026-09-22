defmodule Mix.Tasks.TzWorld.Update do
  @moduledoc """
  Downloads and installs the latest Timezone GeoJSON data.

  ## Arguments

  * `--include-oceans` (`-o`) will include the geojson for the oceans
    in the downloaded data. The default is to download data without
    ocean coverage.

  * `--force` (`-f`) does two things:
      * Forces an update even if the currently installed data is
        already at the latest release. Useful when switching
        between including and excluding ocean coverage.
      * Creates the directory configured under `:data_dir` if it
        does not yet exist. Without `--force` a missing `:data_dir`
        is reported as an error so a misconfigured `:data_dir` is
        loud rather than silently materialised. Pass `--force` on
        the first install when you have set a custom `:data_dir`
        that is not part of the build artifacts.

  * `--backends` (`-b`) is a comma separated list of the backends the
    installed data must serve. The default is `spatial_index`.

    The `.tzw1` data file is the source of truth and is always written.
    Naming `dets` additionally builds `timezones-geodata.dets`, the
    on-disk cache `TzWorld.Backend.DetsWithIndexCache` reads and that
    `TzWorld.Backend.EtsWithIndexCache` loads into ETS at startup, so
    naming `ets` builds it too. That file is an order of magnitude
    larger than the `.tzw1`, and `TzWorld.Backend.SpatialIndex` reads
    the `.tzw1` directly and never needs it, so the default does not
    build it.

    Accepted names are `spatial_index`, `ets` and `dets`. `ets` and
    `dets` are deprecated and will be removed in the next release.

        mix tz_world.update --backends dets
        mix tz_world.update --backends spatial_index,dets

  * `--trace` (`-t`) emits debug-level progress logs (current memory
    usage, download / extract / parse phases).

  """

  @shortdoc "Downloads and installs the latest Timezone GeoJSON data"
  @tag "[TzWorld]"

  @aliases [o: :include_oceans, f: :force, t: :trace, b: :backends]
  @strict [include_oceans: :boolean, force: :boolean, trace: :boolean, backends: :string]

  # Names accepted by `--backends`, mapped to their modules.
  @backend_modules %{
    "spatial_index" => TzWorld.Backend.SpatialIndex,
    "ets" => TzWorld.Backend.EtsWithIndexCache,
    "dets" => TzWorld.Backend.DetsWithIndexCache
  }

  @deprecated_backends ["ets", "dets"]

  # `SpatialIndex` reads the `.tzw1` directly and needs no derived
  # on-disk cache, so it is the default.
  @default_backends "spatial_index"

  use Mix.Task
  alias TzWorld.Downloader
  require Logger

  def run(args) do
    case OptionParser.parse(args, aliases: @aliases, strict: @strict) do
      {options, [], []} ->
        include_oceans? = Keyword.get(options, :include_oceans, false)
        force_update? = Keyword.get(options, :force, false)
        trace? = Keyword.get(options, :trace, false)
        backends = parse_backends(Keyword.get(options, :backends, @default_backends))

        update(include_oceans?, force_update?, trace?, backends)

      _other ->
        Mix.raise(
          """
          Invalid arguments found. `mix tz_world.update` accepts the following:
            --include-oceans
            --no-include-oceans (default)
            --force
            --no-force (default)
            --backends spatial_index,ets,dets (default: spatial_index)
            --trace
            --no-trace (default)
          """,
          exit_status: 1
        )
    end
  end

  def update(include_oceans?, force_update?, trace?) do
    update(include_oceans?, force_update?, trace?, parse_backends(@default_backends))
  end

  def update(include_oceans?, true = _force_update?, trace?, backends) do
    dets_required? = dets_required?(backends)
    start_applications(dets_required?)

    {latest_release, asset_url} = Downloader.latest_release(include_oceans?, trace?)
    # `--force` also creates the configured `:data_dir` if it does not
    # exist (passed as the trailing `force?` arg).
    Downloader.get_latest_release(latest_release, asset_url, trace?, true)

    if dets_required? do
      :ok = TzWorld.Backend.DetsWithIndexCache.stop()
    end

    warn_if_stale_dets(dets_required?)
    :erlang.garbage_collect()
  end

  def update(include_oceans?, false = _force_update?, trace?, backends) do
    dets_required? = dets_required?(backends)
    start_applications(dets_required?)

    case TzWorld.GeoData.stored_version() do
      {:ok, current_release} ->
        cond do
          dets_required? and dets_cache_missing?() ->
            # The .tzw1 source-of-truth is on disk but the .dets cache
            # the runtime backends read isn't. This typically happens
            # after a previous update was interrupted between writing
            # the .tzw1 and rebuilding the DETS file. Rebuild the cache
            # locally — no network round-trip needed.
            Logger.info(
              "#{@tag} TZW1 data is installed (#{current_release}) but the DETS " <>
                "cache at #{dets_cache_path()} is missing. Rebuilding the cache " <>
                "from the existing .tzw1 file without re-downloading. Run " <>
                "`mix tz_world.update` again afterwards if you also want to " <>
                "check for a newer upstream release."
            )

            {:ok, _} = TzWorld.Backend.DetsWithIndexCache.reload_timezone_data()

          true ->
            {latest_release, asset_url} = Downloader.latest_release(include_oceans?, trace?)

            if latest_release > current_release do
              Logger.info(
                "#{@tag} Updating from release #{current_release} to #{latest_release}."
              )

              ensure_data_dir!()
              Downloader.get_latest_release(latest_release, asset_url, trace?)
              warn_if_stale_dets(dets_required?)
            else
              Logger.info(
                "#{@tag} Currently installed release #{current_release} is the latest release."
              )
            end
        end

      {:error, _reason} ->
        {latest_release, asset_url} = Downloader.latest_release(include_oceans?, trace?)

        Logger.info(
          "#{@tag} No timezone geo data installed. Installing the latest release #{latest_release}."
        )

        ensure_data_dir!()
        Downloader.get_latest_release(latest_release, asset_url, trace?)
        warn_if_stale_dets(dets_required?)
    end
  end

  defp parse_backends(names) do
    requested =
      names
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    unknown = Enum.reject(requested, &Map.has_key?(@backend_modules, &1))

    cond do
      unknown != [] ->
        Mix.raise(
          "#{@tag} Unknown backend #{Enum.map_join(unknown, ", ", &inspect/1)}. " <>
            "Known backends are #{Enum.join(known_backends(), ", ")}."
        )

      requested == [] ->
        Mix.raise(
          "#{@tag} --backends requires at least one of #{Enum.join(known_backends(), ", ")}."
        )

      true ->
        log_deprecated_backends(requested)
        MapSet.new(requested)
    end
  end

  defp known_backends do
    @backend_modules |> Map.keys() |> Enum.sort()
  end

  defp log_deprecated_backends(requested) do
    case Enum.filter(requested, &(&1 in @deprecated_backends)) do
      [] ->
        :ok

      deprecated ->
        Logger.info(
          "#{@tag} Backends #{Enum.map_join(deprecated, ", ", &inspect/1)} are " <>
            "deprecated and will be removed in the next release. Use " <>
            "\"spatial_index\" instead."
        )
    end
  end

  # `EtsWithIndexCache` populates its ETS table from the DETS cache at
  # startup, so requesting it requires the DETS file to be built too.
  defp dets_required?(backends) do
    MapSet.member?(backends, "dets") or MapSet.member?(backends, "ets")
  end

  # A `.dets` left from an earlier run is not refreshed when the DETS
  # cache was not requested, so it now describes an older release than
  # the `.tzw1` beside it. Say so rather than let a DETS-backed app
  # silently read stale shapes.
  defp warn_if_stale_dets(true = _dets_required?), do: :ok

  defp warn_if_stale_dets(false = _dets_required?) do
    if File.exists?(dets_cache_path()) do
      Logger.info(
        "#{@tag} #{dets_cache_path()} was not rebuilt because --backends did not " <>
          "include \"dets\", so it is now older than the installed .tzw1 data. " <>
          "Re-run with `--backends dets` if you use DetsWithIndexCache or " <>
          "EtsWithIndexCache, otherwise the file can be deleted."
      )
    end

    :ok
  end

  defp dets_cache_missing? do
    not File.exists?(dets_cache_path())
  end

  defp dets_cache_path do
    TzWorld.Backend.DetsWithIndexCache.filename() |> List.to_string()
  end

  # Pre-flight check: bail with a clean Mix.raise (no stack trace, exit
  # status 1) when the configured `:data_dir` doesn't exist and the user
  # didn't pass `--force`. Only invoked from the non-force update path;
  # `--force` self-heals by creating the directory downstream in
  # `TzWorld.GeoData.open_for_write!/3`.
  defp ensure_data_dir! do
    data_dir = TzWorld.GeoData.data_dir()

    unless File.dir?(data_dir) do
      Mix.raise(
        "#{@tag} Target directory #{inspect(data_dir)} does not exist " <>
          "and --force option was not set. Cannot download timezone data. " <>
          "Either create the directory or re-run with --force."
      )
    end
  end

  defp start_applications(dets_required?) do
    {:ok, _} = Application.ensure_all_started(:tz_world)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:module, _} = Code.ensure_loaded(:ssl_cipher)

    # We deliberately do not start `TzWorld.Backend.SpatialIndex` here:
    # its init logs a warning telling the user to run `mix tz_world.update`,
    # which is exactly what they are already doing. Reading the installed
    # version straight from disk via `TzWorld.GeoData.stored_version/0`
    # avoids the noise and skips loading the shape data into
    # `:persistent_term` only to discard it at task exit.
    #
    # `DetsWithIndexCache` is started only when the DETS cache is wanted.
    # The rebuild that materialises it runs through its GenServer, and
    # `TzWorld.reload_timezone_data/0` only reloads backends that are
    # running -- so not starting it is what keeps the file from being
    # built for a `SpatialIndex` install.
    if dets_required? do
      TzWorld.Backend.DetsWithIndexCache.start_link()
    end

    :ok
  end
end
