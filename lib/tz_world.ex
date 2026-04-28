defmodule TzWorld do
  @moduledoc """
  Resolve a timezone name from coordinates.

  """
  alias Geo.{Point, PointZ}
  import TzWorld.Guards

  @type backend :: module()

  # Reload order matters: `EtsWithIndexCache.load_geodata/0` reads from
  # the DETS file owned by `DetsWithIndexCache`, so DETS must be rebuilt
  # first. `SpatialIndex` reads the on-disk `.tzw1` directly and is
  # order-independent, so it goes last.
  @reload_backends [
    TzWorld.Backend.DetsWithIndexCache,
    TzWorld.Backend.EtsWithIndexCache,
    TzWorld.Backend.SpatialIndex
  ]

  @doc """
  Returns the OTP app name of :tz_world

  """
  def app_name do
    :tz_world
  end

  @doc """
  Returns the installed version of time
  zone data

  ## Example

      TzWorld.version
      => {:ok, "2020d"}

  """
  @spec version :: {:ok, String.t()} | {:error, :enoent}
  def version do
    fetch_backend().version()
  end

  @doc """
  Reload the timezone geometry data from the on-disk files.

  Iterates the list of known backends and asks each one that is
  *currently running in this node* to reload itself from disk.
  Backends that are not running are skipped — the function is safe
  to call regardless of which backends the host application has
  added to its supervision tree.

  ### Returns

  * `{:ok, results}` when every running backend reloaded
    successfully. `results` is a list of `{backend, result}` pairs
    in reload order.

  * `{:error, failures}` when one or more running backends failed
    to reload. `failures` is a list of `{backend, reason}` pairs
    for the backends that did not return `{:ok, _}`.

  ### Notes

  * Reload is performed sequentially in a fixed order
    (`DetsWithIndexCache`, `EtsWithIndexCache`, `SpatialIndex`)
    because `EtsWithIndexCache` reads from the DETS file rebuilt
    by `DetsWithIndexCache`.

  * Each backend's reload runs inside its own GenServer call, so
    concurrent reload requests against a single backend are
    serialized at its mailbox.

  * Lookups during reload are safe: `SpatialIndex` swaps its
    persistent-term entry atomically, and the other backends
    process lookup messages only after the reload returns.

  ### Telemetry

  The reload emits the following events:

  * `[:tz_world, :reload, :start | :stop | :exception]` — wraps the
    full call. `:stop` measurements include `:duration`. `:stop`
    metadata includes `:result` (the return value), `:backends`
    (list of running backends that participated), and
    `:failure_count`.

  * `[:tz_world, :reload, :backend, :start | :stop | :exception]` —
    wraps each per-backend reload. Metadata includes `:backend`
    (the module). `:stop` metadata also includes `:result`.

  ### Example

      # An app running only the default backend
      TzWorld.reload_timezone_data()
      #=> {:ok, [{TzWorld.Backend.SpatialIndex, {:ok, :loaded}}]}

  """
  @type backend_result :: {:ok, term()} | {:error, term()}
  @spec reload_timezone_data() ::
          {:ok, [{module(), backend_result}]} | {:error, [{module(), term()}]}
  def reload_timezone_data do
    :telemetry.span([:tz_world, :reload], %{}, fn ->
      results =
        Enum.flat_map(@reload_backends, fn backend ->
          case Process.whereis(backend) do
            nil -> []
            _pid -> [{backend, reload_backend(backend)}]
          end
        end)

      failures =
        Enum.reject(results, fn {_backend, result} -> match?({:ok, _}, result) end)

      reply = if failures == [], do: {:ok, results}, else: {:error, failures}

      stop_metadata = %{
        result: reply,
        backends: Enum.map(results, fn {backend, _} -> backend end),
        failure_count: length(failures)
      }

      {reply, stop_metadata}
    end)
  end

  defp reload_backend(backend) do
    :telemetry.span([:tz_world, :reload, :backend], %{backend: backend}, fn ->
      result = apply(backend, :reload_timezone_data, [])
      {result, %{backend: backend, result: result}}
    end)
  end

  @doc """
  Returns the *first* timezone name found for the given
  coordinates specified as either a `Geo.Point`,
  a `Geo.PointZ` or a tuple `{lng, lat}`

  ## Arguments

  * `point` is a `Geo.Point.t()` a `Geo.PointZ.t()` or
    a tuple `{lng, lat}`

  * `backend` is any backend access module.

  ## Returns

  * `{:ok, timezone}` or

  * `{:error, :time_zone_not_found}`

  ## Notes

  Note that the point is always expressed as
  `lng` followed by `lat`.

  ## Examples

      iex> TzWorld.timezone_at(%Geo.Point{coordinates: {3.2, 45.32}})
      {:ok, "Europe/Paris"}

      iex> TzWorld.timezone_at({3.2, 45.32})
      {:ok, "Europe/Paris"}

      iex> TzWorld.timezone_at({0.0, 0.0})
      {:error, :time_zone_not_found}


  The algorithm starts by filtering out timezones whose bounding
  box does not contain the given point.

  Once filtered, the *first* timezone which contains the given
  point is returned, or an error tuple if none of the
  timezones match.

  In rare cases, typically due to territorial disputes,
  one or more timezones may apply to a given location.
  This function returns the first time zone that matches.

  """
  @spec timezone_at(Geo.Point.t(), backend) ::
          {:ok, String.t()} | {:error, atom}

  def timezone_at(point, backend \\ fetch_backend())

  def timezone_at(%Point{} = point, backend) when is_atom(backend) do
    backend.timezone_at(point)
  end

  @spec timezone_at(Geo.PointZ.t(), backend) ::
          {:ok, String.t()} | {:error, atom}

  def timezone_at(%PointZ{coordinates: {lng, lat, _alt}}, backend) when is_atom(backend) do
    point = %Point{coordinates: {lng, lat}}
    backend.timezone_at(point)
  end

  @spec timezone_at({lng :: number, lat :: number}, backend) ::
          {:ok, String.t()} | {:error, atom}

  def timezone_at({lng, lat}, backend) when is_lng(lng) and is_lat(lat) do
    point = %Geo.Point{coordinates: {lng, lat}}
    backend.timezone_at(point)
  end

  @doc """
  Returns all timezone name found for the given
  coordinates specified as either a `Geo.Point`,
  a `Geo.PointZ` or a tuple `{lng, lat}`

  ## Arguments

  * `point` is a `Geo.Point.t()` a `Geo.PointZ.t()` or
    a tuple `{lng, lat}`

  * `backend` is any backend access module.

  ## Returns

  * `{:ok, timezone}` or

  * `{:error, :time_zone_not_found}`

  ## Notes

  Note that the point is always expressed as
  `lng` followed by `lat`.

  ## Examples

      iex> TzWorld.all_timezones_at(%Geo.Point{coordinates: {3.2, 45.32}})
      {:ok, ["Europe/Paris"]}

      iex> TzWorld.all_timezones_at({3.2, 45.32})
      {:ok, ["Europe/Paris"]}

      iex> TzWorld.all_timezones_at({0.0, 0.0})
      {:ok, []}


  The algorithm starts by filtering out timezones whose bounding
  box does not contain the given point.

  Once filtered, all timezones which contains the given
  point is returned, or an error tuple if none of the
  timezones match.

  In rare cases, typically due to territorial disputes,
  one or more timezones may apply to a given location.
  This function returns all time zones that match.

  """
  @spec all_timezones_at(Geo.Point.t(), backend) ::
          {:ok, [String.t()]}

  def all_timezones_at(point, backend \\ fetch_backend())

  def all_timezones_at(%Point{} = point, backend) when is_atom(backend) do
    backend.all_timezones_at(point)
  end

  @spec all_timezones_at(Geo.PointZ.t(), backend) ::
          {:ok, [String.t()]}

  def all_timezones_at(%PointZ{coordinates: {lng, lat, _alt}}, backend) when is_atom(backend) do
    point = %Point{coordinates: {lng, lat}}
    backend.all_timezones_at(point)
  end

  @spec all_timezones_at({lng :: number, lat :: number}, backend) ::
          {:ok, [String.t()]}

  def all_timezones_at({lng, lat}, backend) when is_lng(lng) and is_lat(lat) do
    point = %Geo.Point{coordinates: {lng, lat}}
    backend.all_timezones_at(point)
  end

  @doc false
  def contains?(%Geo.MultiPolygon{} = multi_polygon, %Geo.Point{} = point) do
    multi_polygon.coordinates
    |> Enum.any?(fn polygon -> contains?(%Geo.Polygon{coordinates: polygon}, point) end)
  end

  def contains?(%Geo.Polygon{coordinates: [envelope | holes]}, %Geo.Point{coordinates: point}) do
    interior?(envelope, point) && disjoint?(holes, point)
  end

  def contains?(bounding_boxes, point) when is_list(bounding_boxes) do
    Enum.any?(bounding_boxes, &contains?(&1, point))
  end

  defp interior?(ring, {px, py}) do
    ring = for {x, y} <- ring, do: {x - px, y - py}
    crosses = count_crossing(ring)
    rem(crosses, 2) == 1
  end

  defp disjoint?(rings, point) do
    Enum.all?(rings, fn ring -> !interior?(ring, point) end)
  end

  defp count_crossing([_]), do: 0

  defp count_crossing([{ax, ay}, {bx, by} | rest]) do
    crosses = count_crossing([{bx, by} | rest])

    if ay > 0 != by > 0 && (ax * by - bx * ay) / (by - ay) > 0 do
      crosses + 1
    else
      crosses
    end
  end

  @default_backend_precedence [
    TzWorld.Backend.SpatialIndex,
    TzWorld.Backend.EtsWithIndexCache,
    TzWorld.Backend.DetsWithIndexCache
  ]

  def fetch_backend do
    backends =
      [Application.get_env(:tz_world, :default_backend) | @default_backend_precedence]
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    Enum.find(backends, &Process.whereis/1) ||
      raise(
        RuntimeError,
        "No TzWorld backend appears to be running. " <>
          "please add one of #{inspect(backends)} to your supervision tree"
      )
  end

  @doc false
  require Logger
  def maybe_log(message, trace? \\ false)

  def maybe_log(message, true) do
    memory = trunc(:erlang.memory()[:total] / 1_048_576)
    Logger.debug("[#{memory} MiB] " <> message)
  end

  def maybe_log(_message, false) do
    nil
  end
end
