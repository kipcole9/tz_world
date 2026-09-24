defmodule TzWorld.Backend.SpatialIndex do
  @moduledoc """
  Resolves timezones from a coordinate using an R-tree spatial index
  held in `:persistent_term`.

  This is the recommended backend and is also the default — applications
  that do not pin `:default_backend` will pick it up automatically as
  long as it is started in the supervision tree.

  ## How it works

  At startup the backend reads the compressed timezone shape data that
  `mix tz_world.update` installs and builds two structures:

  * a Sort-Tile-Recursive packed R-tree over every shape's bounding
    box, with one entry per sub-polygon of a `Geo.MultiPolygon`;

  * each shape compiled by `TzWorld.PackedGeometry`: its rings packed
    into binaries, with their edges indexed by horizontal band.

  Both are stored with the data version as a single term under one
  `:persistent_term` key. A lookup finds candidate shapes in the
  R-tree, then tests each against only the ring edges in the query
  point's band — typically a few dozen, even in rings with nearly
  200,000 vertices — so it takes microseconds.

  Lookups (`TzWorld.timezone_at/1` and `TzWorld.all_timezones_at/1`)
  read the stored term directly. They do not go through the GenServer
  mailbox and do not copy any term, which makes them lock-free and
  safe to call from any number of processes concurrently.

  ## Reload

  `reload_timezone_data/0` rebuilds the index and replaces the stored
  term in one `:persistent_term.put/2`. Lookups carry on against the
  previous index until then, so a reload never blocks them. Loading
  and reloading compile the shapes in parallel, one task per shape, and
  take a couple of seconds on a multi-core machine and several on a
  single core. The put also triggers a global garbage collection for
  every process that references a persistent term — fine when reload
  is invoked after a data update, costly on a hot path. Reload should
  not be called on every request.

  ## Memory profile

  About 150 MB for the data without ocean coverage, the default. Ring
  vertices are held as packed binaries at 16 bytes a vertex, and those
  binaries live off-heap: `:persistent_term.info/0` reports only the
  small term that refers to them, so measure `:erlang.memory/1`
  instead.

  ## Public API

  In normal use you will not call functions on this module directly —
  use `TzWorld.timezone_at/1`, `TzWorld.all_timezones_at/1`,
  `TzWorld.version/0`, and `TzWorld.reload_timezone_data/0`. Add this
  module to your supervision tree to make it the running backend:

      children = [
        TzWorld.Backend.SpatialIndex
      ]

  """

  @behaviour TzWorld.Backend

  use GenServer
  require Logger

  alias TzWorld.{GeoData, PackedGeometry, SpatialIndex}
  alias Geo.Point

  # A reload rebuilds the packed geometry for every shape: a couple of seconds
  # on a multi-core machine, several on a single core and more on a slow one.
  # Lookups keep reading the previous index until the rebuilt one is swapped
  # in, so a generous wait costs nothing but the caller's patience.
  @reload_timeout 120_000

  # All loaded state lives under a single `:persistent_term` key so the
  # reload swap is atomic: lookups always observe a consistent
  # `{version, shapes_tuple, tree}` triple. Three separate puts (one per
  # field) would (a) let lookups race with reload and walk an old tree
  # against a new shapes tuple, and (b) trigger a global GC on every put
  # rather than once per reload.
  @index_key {__MODULE__, :index}

  @doc """
  Start the backend and bulk-load the spatial index.

  The load is performed synchronously inside `init/1`, so once
  `start_link/1` returns the index is in `:persistent_term` and
  lookups are immediately ready to serve.

  ### Arguments

  * `options` is a keyword list passed through to
    `GenServer.start_link/3`. There are no backend-specific options.

  ### Returns

  * `{:ok, pid}` if the backend started and finished loading.

  * `{:error, reason}` if the compressed timezone data could not be
    found or decoded — typically because `mix tz_world.update` has not
    yet been run.

  """
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @doc false
  def stop(reason \\ :normal, timeout \\ :infinity) do
    GenServer.stop(__MODULE__, reason, timeout)
  end

  @doc false
  def init(_options) do
    # Load synchronously so callers that bypass the GenServer mailbox
    # (timezone_at/1, all_timezones_at/1) see a populated
    # persistent_term as soon as start_link/1 returns.
    #
    # Missing data must not crash init: `mix tz_world.update` starts
    # this backend before the data file exists on a fresh install, and
    # users who add this backend to their supervision tree before
    # running the update task should see a graceful degraded state
    # rather than a supervisor boot failure. Lookups against an
    # unloaded backend return `{:error, :enoent}`.
    case load_into_persistent_term() do
      :ok ->
        {:ok, :ready}

      {:error, reason} ->
        Logger.warning(
          "[TzWorld.Backend.SpatialIndex] started without timezone data " <>
            "(#{inspect(reason)}). Run `mix tz_world.update` to install " <>
            "the data, then call `TzWorld.reload_timezone_data/0`."
        )

        {:ok, :unloaded}
    end
  end

  @doc false
  def version do
    case :persistent_term.get(@index_key, nil) do
      nil -> {:error, :enoent}
      {version, _shapes, _tree} -> {:ok, version}
    end
  end

  @doc false
  @spec timezone_at(Geo.Point.t()) :: {:ok, String.t()} | {:error, atom}
  def timezone_at(%Point{coordinates: {lng, lat}}) do
    with {:ok, tree, zones} <- fetch_index() do
      tree
      |> SpatialIndex.stab(lng, lat)
      |> dedupe_walk(zones, lng, lat)
    end
  end

  @doc false
  @spec all_timezones_at(Geo.Point.t()) :: {:ok, [String.t()]} | {:error, atom}
  def all_timezones_at(%Point{coordinates: {lng, lat}}) do
    with {:ok, tree, zones} <- fetch_index() do
      tzids =
        tree
        |> SpatialIndex.stab(lng, lat)
        |> Enum.uniq()
        |> Enum.reduce([], fn id, acc ->
          {tzid, polygons} = :erlang.element(id + 1, zones)
          if PackedGeometry.contains?(polygons, lng, lat), do: [tzid | acc], else: acc
        end)
        |> Enum.reverse()

      {:ok, tzids}
    end
  end

  @doc false
  @spec reload_timezone_data :: {:ok, term} | {:error, term}
  def reload_timezone_data do
    GenServer.call(__MODULE__, :reload_data, @reload_timeout)
  end

  # --- Server callbacks

  @doc false
  def handle_call(:reload_data, _from, _state) do
    case load_into_persistent_term() do
      :ok -> {:reply, {:ok, :loaded}, :ready}
      error -> {:reply, error, error}
    end
  end

  # --- Lookup helpers

  defp fetch_index do
    case :persistent_term.get(@index_key, nil) do
      nil ->
        {:error, :enoent}

      {_version, zones, tree} ->
        {:ok, tree, zones}
    end
  end

  # Walk candidate ids, skipping duplicates without an upfront uniq pass.
  # Candidate sets are typically small (1–10), so an inline-seen list is
  # faster than building a MapSet.
  defp dedupe_walk(ids, zones, lng, lat), do: dedupe_walk(ids, zones, lng, lat, [])

  defp dedupe_walk([], _zones, _lng, _lat, _seen), do: {:error, :time_zone_not_found}

  defp dedupe_walk([id | rest], zones, lng, lat, seen) do
    if id in seen do
      dedupe_walk(rest, zones, lng, lat, seen)
    else
      {tzid, polygons} = :erlang.element(id + 1, zones)

      if PackedGeometry.contains?(polygons, lng, lat) do
        {:ok, tzid}
      else
        dedupe_walk(rest, zones, lng, lat, [id | seen])
      end
    end
  end

  # --- Loader

  defp load_into_persistent_term do
    with {:ok, version, records} <- GeoData.stream_shape_records() do
      # Shapes are decoded and compiled in parallel, and each task drops its
      # Geo struct once compiled, so the lists-of-tuples geometry is never held
      # all at once. Results are collected in file order, the order the R-tree
      # entries have always been built in: it decides the order candidates are
      # returned in, and so which zone `timezone_at/1` reports where zones
      # overlap.
      {zones, entries} =
        records
        |> Stream.with_index()
        |> Task.async_stream(&compile_record/1, ordered: true, timeout: :infinity)
        |> Enum.map(fn {:ok, compiled} -> compiled end)
        |> Enum.unzip()

      tree = SpatialIndex.build(Enum.concat(entries))

      # Single atomic put: lookups either see the entire previous index
      # or the entire new one, never a half-replaced state.
      :persistent_term.put(@index_key, {version, List.to_tuple(zones), tree})

      :ok
    end
  end

  defp compile_record({record, index}) do
    shape = :erlang.binary_to_term(record)
    {PackedGeometry.compile(shape), shape_to_entries(shape, index)}
  end

  defp shape_to_entries(%{properties: %{bounding_box: %Geo.Polygon{} = bbox}}, index) do
    [bbox_to_entry(bbox, index)]
  end

  defp shape_to_entries(%{properties: %{bounding_box: bboxes}}, index) when is_list(bboxes) do
    Enum.map(bboxes, &bbox_to_entry(&1, index))
  end

  defp bbox_to_entry(%Geo.Polygon{coordinates: [ring | _]}, index) do
    {xmin, xmax, ymin, ymax} =
      Enum.reduce(ring, {180.0, -180.0, 90.0, -90.0}, fn {x, y}, {xmin, xmax, ymin, ymax} ->
        {min(x, xmin), max(x, xmax), min(y, ymin), max(y, ymax)}
      end)

    {xmin, xmax, ymin, ymax, index}
  end
end
