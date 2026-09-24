defmodule TzWorld do
  @moduledoc """
  Resolves the time zone at a location from its coordinates.

  Time zone boundaries come from the
  [timezone-boundary-builder](https://github.com/evansiroky/timezone-boundary-builder)
  project. They are not included in the package: `mix tz_world.update`
  downloads and installs them, and lookups return `{:error, :enoent}`
  until it has run.

  Lookups are answered by a backend running in the application's
  supervision tree, normally `TzWorld.Backend.SpatialIndex`.

  ### Public API

  * `timezone_at/2` returns the time zone at a point.

  * `all_timezones_at/2` returns every time zone at a point, for the few
    places where zones overlap.

  * `version/0` returns the version of the installed data.

  * `reload_timezone_data/0` reloads the running backends after the data
    is updated.

  """
  alias Geo.{Point, PointZ}
  import TzWorld.Guards

  @typedoc "A backend module implementing `TzWorld.Backend`."
  @type backend :: module()

  @typedoc """
  A location as a `Geo.Point`, a `Geo.PointZ` or a `{longitude, latitude}`
  tuple, in degrees.
  """
  @type point :: Geo.Point.t() | Geo.PointZ.t() | {lng :: number(), lat :: number()}

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
  Returns the OTP application name of `tz_world`.

  ### Returns

  * `:tz_world`.

  ### Examples

      iex> TzWorld.app_name()
      :tz_world

  """
  @spec app_name :: :tz_world
  def app_name do
    :tz_world
  end

  @doc """
  Returns the version of the installed time zone data.

  The version is read from the running backend.

  ### Returns

  * `{:ok, version}` where `version` is the name of the upstream data
    release, such as `"2026d"`.

  * `{:error, :enoent}` if the time zone data has not been installed.

  ### Examples

      iex> {:ok, version} = TzWorld.version()
      iex> is_binary(version)
      true

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

  ### Examples

  In an application running only the default backend:

      iex> TzWorld.reload_timezone_data()
      {:ok, [{TzWorld.Backend.SpatialIndex, {:ok, :loaded}}]}

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
  Returns the time zone at a point.

  Where time zones overlap, which happens in a few disputed territories,
  the first one found is returned. `all_timezones_at/2` returns them all.

  ### Arguments

  * `point` is a `Geo.Point`, a `Geo.PointZ` or a `{longitude, latitude}`
    tuple, in degrees. Longitude always comes first.

  * `backend` is the backend module to query. The default is the running
    backend, preferring the configured `:default_backend`. A `RuntimeError`
    is raised if no backend is running.

  ### Returns

  * `{:ok, time_zone}` where `time_zone` is the name of the time zone.

  * `{:error, :time_zone_not_found}` if no time zone contains the point.

  * `{:error, :invalid_point}` if `point` is not one of the forms above, or
    its longitude is outside -180..180 or its latitude outside -90..90.

  * `{:error, :enoent}` if the time zone data has not been installed. Run
    `mix tz_world.update` to install it.

  ### Examples

      iex> TzWorld.timezone_at(%Geo.Point{coordinates: {3.2, 45.32}})
      {:ok, "Europe/Paris"}

      iex> TzWorld.timezone_at({3.2, 45.32})
      {:ok, "Europe/Paris"}

      iex> TzWorld.timezone_at({0.0, 0.0})
      {:error, :time_zone_not_found}

      iex> TzWorld.timezone_at({200.0, 45.32})
      {:error, :invalid_point}

  """
  @spec timezone_at(point(), backend()) :: {:ok, String.t()} | {:error, atom()}
  def timezone_at(point, backend \\ fetch_backend()) when is_atom(backend) do
    case validate_point(point) do
      {:ok, point} -> backend.timezone_at(point)
      :error -> {:error, :invalid_point}
    end
  end

  @doc """
  Returns every time zone at a point.

  Most points are in exactly one time zone. A few, in disputed
  territories, are in more than one, and points outside every time zone
  are in none.

  ### Arguments

  * `point` is a `Geo.Point`, a `Geo.PointZ` or a `{longitude, latitude}`
    tuple, in degrees. Longitude always comes first.

  * `backend` is the backend module to query. The default is the running
    backend, preferring the configured `:default_backend`. A `RuntimeError`
    is raised if no backend is running.

  ### Returns

  * `{:ok, time_zones}` where `time_zones` is a list of time zone names in
    the order they were found, empty if no time zone contains the point.

  * `{:error, :invalid_point}` if `point` is not one of the forms above, or
    its longitude is outside -180..180 or its latitude outside -90..90.

  * `{:error, :enoent}` if the time zone data has not been installed. Run
    `mix tz_world.update` to install it.

  ### Examples

      iex> TzWorld.all_timezones_at({3.2, 45.32})
      {:ok, ["Europe/Paris"]}

      iex> TzWorld.all_timezones_at({87.6168, 43.8256})
      {:ok, ["Asia/Shanghai", "Asia/Urumqi"]}

      iex> TzWorld.all_timezones_at({0.0, 0.0})
      {:ok, []}

  """
  @spec all_timezones_at(point(), backend()) :: {:ok, [String.t()]} | {:error, atom()}
  def all_timezones_at(point, backend \\ fetch_backend()) when is_atom(backend) do
    case validate_point(point) do
      {:ok, point} -> backend.all_timezones_at(point)
      :error -> {:error, :invalid_point}
    end
  end

  # Whatever the caller passes, only a well-formed point in range reaches a
  # backend, so backends can rely on numeric coordinates.
  defp validate_point(%Point{coordinates: {lng, lat}} = point) when is_lng(lng) and is_lat(lat),
    do: {:ok, point}

  defp validate_point(%PointZ{coordinates: {lng, lat, _alt}}) when is_lng(lng) and is_lat(lat),
    do: {:ok, %Point{coordinates: {lng, lat}}}

  defp validate_point({lng, lat}) when is_lng(lng) and is_lat(lat),
    do: {:ok, %Point{coordinates: {lng, lat}}}

  defp validate_point(_point), do: :error

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

  # Even-odd ray casting: a ray from the point towards +x crosses the ring an odd
  # number of times exactly when the point is inside. Each vertex is translated
  # relative to the point as it is read, in one tail-recursive pass, rather than
  # building a translated copy of the whole ring first and then recursing over
  # it one stack frame per vertex. The crossing test itself is unchanged.
  defp interior?([], _point), do: false

  defp interior?([{x, y} | rest], {px, py}) do
    rem(count_crossings(rest, x - px, y - py, px, py, 0), 2) == 1
  end

  defp disjoint?(rings, point) do
    Enum.all?(rings, fn ring -> !interior?(ring, point) end)
  end

  defp count_crossings([], _ax, _ay, _px, _py, crossings), do: crossings

  defp count_crossings([{x, y} | rest], ax, ay, px, py, crossings) do
    bx = x - px
    by = y - py

    crossings =
      if ay > 0 != by > 0 && (ax * by - bx * ay) / (by - ay) > 0 do
        crossings + 1
      else
        crossings
      end

    count_crossings(rest, bx, by, px, py, crossings)
  end

  @default_backend_precedence [
    TzWorld.Backend.SpatialIndex,
    TzWorld.Backend.EtsWithIndexCache,
    TzWorld.Backend.DetsWithIndexCache
  ]

  @doc false
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
