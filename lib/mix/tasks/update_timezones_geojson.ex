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

    :ok = TzWorld.Backend.SpatialIndex.stop()
    :ok = TzWorld.Backend.DetsWithIndexCache.stop()
    :erlang.garbage_collect()
  end

  def update(include_oceans?, false = _force_update?, trace?) do
    start_applications()

    case Downloader.current_release() do
      {:ok, current_release} ->
        {latest_release, asset_url} = Downloader.latest_release(include_oceans?, trace?)

        if latest_release > current_release do
          Logger.info("#{@tag} Updating from release #{current_release} to #{latest_release}.")
          Downloader.get_latest_release(latest_release, asset_url, trace?)
        else
          Logger.info(
            "#{@tag} Currently installed release #{current_release} is the latest release."
          )
        end

      {:error, :enoent} ->
        {latest_release, asset_url} = Downloader.latest_release(include_oceans?, trace?)

        Logger.info(
          "#{@tag} No timezone geo data installed. Installing the latest release #{latest_release}."
        )

        Downloader.get_latest_release(latest_release, asset_url, trace?)
    end
  end

  defp start_applications do
    {:ok, _} = Application.ensure_all_started(:tz_world)
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:module, _} = Code.ensure_loaded(:ssl_cipher)

    TzWorld.Backend.SpatialIndex.start_link()
    TzWorld.Backend.DetsWithIndexCache.start_link()
  end
end
