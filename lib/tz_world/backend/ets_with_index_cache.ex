defmodule TzWorld.Backend.EtsWithIndexCache do
  @moduledoc false

  @behaviour TzWorld.Backend

  use GenServer
  require Logger

  alias Geo.Point

  @timeout 10_000
  @tz_world_version :tz_world_version

  @doc false
  @options [:named_table, :compressed, read_concurrency: true]
  def start_link(options \\ @options) do
    options = if options == [], do: @options, else: options
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @doc false
  def stop(reason \\ :normal, timeout \\ :infinity) do
    GenServer.stop(__MODULE__, reason, timeout)
  end

  @doc false
  def init(options) do
    {:ok, [], {:continue, {:load_data, options}}}
  end

  @doc false
  def version do
    GenServer.call(__MODULE__, :version, @timeout)
  end

  @doc false
  @spec timezone_at(Geo.Point.t()) :: {:ok, String.t()} | {:error, atom}
  def timezone_at(%Point{} = point) do
    GenServer.call(__MODULE__, {:timezone_at, point}, @timeout)
  end

  @doc false
  @spec all_timezones_at(Geo.Point.t()) :: {:ok, [String.t()]} | {:error, atom}
  def all_timezones_at(%Point{} = point) do
    GenServer.call(__MODULE__, {:all_timezones_at, point}, @timeout)
  end

  @doc false
  @spec reload_timezone_data :: {:ok, term}
  def reload_timezone_data do
    GenServer.call(__MODULE__, :reload_data, @timeout)
  end

  @doc false
  def load_geodata do
    case TzWorld.Backend.DetsWithIndexCache.get_geodata_table() do
      {:ok, t} ->
        # Clear any stale entries from a previous load. `:dets.to_ets/2`
        # only inserts; without this, shapes that were removed upstream
        # (or whose bounding-box key changed slightly between releases)
        # would persist in ETS forever after a reload.
        :ets.delete_all_objects(__MODULE__)
        result = :dets.to_ets(t, __MODULE__)

        # Release our reference to the DETS file. `:dets.open_file/2`
        # ref-counts opens by name, so leaving this open would prevent
        # `DetsWithIndexCache.reload_data` from later reopening the
        # file in `:read_write` mode (failing with
        # `:incompatible_arguments`). ETS lookups don't go through
        # DETS, so we don't need it open between loads. Tolerate any
        # close error — the table being already closed is harmless.
        _ = :dets.close(t)

        case result do
          {:error, _} = error -> error
          _ets_table -> :ok
        end

      {:error, _} = error ->
        error
    end
  end

  # --- Server callback implementation

  @doc false
  def handle_continue({:load_data, options}, _state) do
    ensure_table!(options)

    case load_geodata() do
      :ok ->
        {:noreply, get_index_cache()}

      {:error, reason} ->
        # Don't crash the supervisor on a missing or transiently
        # unreadable DETS file. Mirror `SpatialIndex`'s behaviour:
        # log a warning and stay alive in a degraded state. Lookups
        # and `version/0` will return `{:error, :enoent}` until
        # `reload_timezone_data/0` is called with valid data on disk.
        Logger.warning(
          "[TzWorld.Backend.EtsWithIndexCache] started without timezone data " <>
            "(#{inspect(reason)})."
        )

        {:noreply, []}
    end
  end

  defp ensure_table!(options) do
    case :ets.whereis(__MODULE__) do
      :undefined -> :ets.new(__MODULE__, options)
      _ref -> __MODULE__
    end
  end

  @doc false
  def handle_call({:timezone_at, %Geo.Point{} = point}, _from, state) do
    {:reply, find_zone(point, state), state}
  end

  @doc false
  def handle_call({:all_timezones_at, %Geo.Point{} = point}, _from, state) do
    {:reply, find_zones(point, state), state}
  end

  @doc false
  def handle_call(:version, _from, state) do
    case :ets.lookup(__MODULE__, @tz_world_version) do
      [{_, version}] -> {:reply, {:ok, version}, state}
      [] -> {:reply, {:error, :enoent}, state}
    end
  end

  @doc false
  def handle_call(:reload_data, _from, _state) do
    case load_geodata() do
      :ok -> {:reply, {:ok, :loaded}, get_index_cache()}
      {:error, _} = error -> {:reply, error, []}
    end
  end

  defp find_zone(%Geo.Point{} = point, state) do
    point
    |> select_candidates(state)
    |> Enum.find(&TzWorld.contains?(&1, point))
    |> case do
      %Geo.MultiPolygon{properties: %{tzid: tzid}} -> {:ok, tzid}
      %Geo.Polygon{properties: %{tzid: tzid}} -> {:ok, tzid}
      nil -> {:error, :time_zone_not_found}
    end
  end

  defp find_zones(%Geo.Point{} = point, state) do
    point
    |> select_candidates(state)
    |> Enum.filter(&TzWorld.contains?(&1, point))
    |> Enum.map(& &1.properties.tzid)
    |> wrap(:ok)
  end

  defp wrap(term, atom) do
    {atom, term}
  end

  defp select_candidates(%{coordinates: {lng, lat}}, state) do
    Enum.filter(state, fn {x_min, x_max, y_min, y_max} ->
      lng >= x_min && lng <= x_max && lat >= y_min && lat <= y_max
    end)
    |> Enum.map(fn bounding_box ->
      [{_key, value}] = :ets.lookup(__MODULE__, bounding_box)
      value
    end)
  end

  def get_index_cache do
    :ets.select(__MODULE__, index_spec())
  end

  def index_spec do
    [{{{:"$1", :"$2", :"$3", :"$4"}, :"$5"}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]}]
  end
end
