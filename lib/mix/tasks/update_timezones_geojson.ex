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

  * `--trace` (`-t`) emits debug-level progress logs (current memory
    usage, download / extract / parse phases).

  """

  @shortdoc "Downloads and installs the latest Timezone GeoJSON data"
  @tag "[TzWorld]"

  @aliases [o: :include_oceans, f: :force, t: :trace]
  @strict [include_oceans: :boolean, force: :boolean, trace: :boolean]

  use Mix.Task
  alias TzWorld.Downloader
  require Logger

  def run(args) do
    case OptionParser.parse(args, aliases: @aliases, strict: @strict) do
      {options, [], []} ->
        include_oceans? = Keyword.get(options, :include_oceans, false)
        force_update? = Keyword.get(options, :force, false)
        trace? = Keyword.get(options, :trace, false)

        update(include_oceans?, force_update?, trace?)

      _other ->
        Mix.raise(
          """
          Invalid arguments found. `mix tz_world.update` accepts the following:
            --include-oceans
            --no-include-oceans (default)
            --force
            --no-force (default)
            --trace
            --no-trace (default)
          """,
          exit_status: 1
        )
    end
  end

  def update(include_oceans?, true = _force_update?, trace?) do
    start_applications()

    {latest_release, asset_url} = Downloader.latest_release(include_oceans?, trace?)
    # `--force` also creates the configured `:data_dir` if it does not
    # exist (passed as the trailing `force?` arg).
    Downloader.get_latest_release(latest_release, asset_url, trace?, true)

    :ok = TzWorld.Backend.DetsWithIndexCache.stop()
    :erlang.garbage_collect()
  end

  def update(include_oceans?, false = _force_update?, trace?) do
    start_applications()

    case TzWorld.GeoData.stored_version() do
      {:ok, current_release} ->
        cond do
          dets_cache_missing?() ->
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
    end
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

  defp start_applications do
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
    # `DetsWithIndexCache` is still required: the post-download rebuild
    # goes through its GenServer (`reload_timezone_data/0`).
    TzWorld.Backend.DetsWithIndexCache.start_link()
  end
end
