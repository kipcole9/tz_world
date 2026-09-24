defmodule TzWorld.Backend do
  @moduledoc """
  The behaviour a time zone lookup backend implements.

  `TzWorld` answers lookups by calling the running backend, normally
  `TzWorld.Backend.SpatialIndex`. A custom backend implements these
  callbacks, runs in the application's supervision tree registered under
  its module name, and is made the default with:

      config :tz_world, default_backend: MyApp.TzWorldBackend

  `TzWorld` validates points before it calls a backend, so a backend
  always receives a `Geo.Point` whose coordinates are numbers within
  range.

  """

  @typedoc "Latitude in degrees, from -90 to 90."
  @type lat :: number()

  @typedoc "Longitude in degrees, from -180 to 180."
  @type lng :: number()

  @typedoc "A point whose coordinates are `{lng, lat}`."
  @type geo :: Geo.Point.t()

  @doc """
  Returns the time zone at a point: `{:ok, time_zone}`, or
  `{:error, :time_zone_not_found}` if no time zone contains it.
  """
  @callback timezone_at(geo) :: {:ok, String.t()} | {:error, atom}

  @doc """
  Returns every time zone at a point, as `{:ok, time_zones}` with an
  empty list if no time zone contains it.
  """
  @callback all_timezones_at(geo) :: {:ok, [String.t()]} | {:error, atom}

  @doc """
  Reloads the time zone data after `mix tz_world.update` has installed a
  new release.
  """
  @callback reload_timezone_data :: {:ok, term} | {:error, term}

  @doc """
  Returns the version of the loaded time zone data, as `{:ok, version}`.
  """
  @callback version :: {:ok, String.t()} | {:error, term}
end
