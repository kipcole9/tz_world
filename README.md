# TzWorld

[![hex.pm](https://img.shields.io/hexpm/v/tz_world.svg)](https://hex.pm/packages/tz_world)
[![hex.pm](https://img.shields.io/hexpm/dt/tz_world.svg)](https://hex.pm/packages/tz_world)
[![hex.pm](https://img.shields.io/hexpm/l/tz_world.svg)](https://hex.pm/packages/tz_world)
[![github.com](https://img.shields.io/github/last-commit/kipcole9/tz_world.svg)](https://github.com/kipcole9/tz_world)

Resolve timezones from a location using data from the
[timezone-boundary-builder](https://github.com/evansiroky/timezone-boundary-builder)
project.

> #### Upgrading from 1.x {: .warning}
>
> The on-disk data format changed in 2.x: `priv/timezones-geodata.tzw1` replaces `priv/timezones-geodata.etf.zip`. After upgrading you must run `mix tz_world.update` once to reinstall the data in the new format. Until you do, every lookup returns `{:error, :time_zone_not_found}`. The old `.etf.zip` and `.dets` files in `priv/` are no longer read and can be deleted to reclaim disk space (≈ 900 MB).

## Installation

Add `tz_world` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tz_world, "~> 2.0"}
  ]
end
```

After adding `TzWorld` as a dependency, run `mix deps.get` to install it. Then run `mix tz_world.update` to install the timezone data.

**NOTE** No data is installed with the package and until the data is installed
with `mix tz_world.update` all calls to `TzWorld.timezone_at/1` will return
`{:error, :time_zone_not_found}`.

### Configuration

There is no mandatory configuration required however four options may be configured in `config.exs`:

```elixir
config :tz_world,
  # Configure a custom TzWorld backend. It will be used
  # as the default backend in calls to `TzWorld.timezone_at/1`
  default_backend: MyTzWorldBackend,
  # The default is the `priv` directory of `:tz_world`
  data_dir: "geodata/directory",
  # The default is either the trust store included in the
  # libraries `CAStore` or `certifi` or the platform
  # trust store.
  cacertfile: "path/to/ca_trust_store",
  # The default is no options, however one can set any `httpc` client options.
  httpc_opts: [
    proxy: {{String.to_charlist(proxy_host), proxy_port}, []}
  ]
```    
## Backend selection

`TzWorld` provides alternative strategies for managing access to the backend data. Each backend is implemented as a `GenServer` that needs to be either manually started with `BackendModule.start_link/1` or preferably added to your application's supervision tree.

The recommended backend is `TzWorld.Backend.SpatialIndex`. It is also the default — applications that do not pin `:default_backend` will pick it up automatically.

For example:

```elixir
defmodule MyApp.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      ...
      TzWorld.Backend.SpatialIndex
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```
The following backends are available:

* `TzWorld.Backend.SpatialIndex` (recommended, default) resolves a point by
  querying an R-tree spatial index built once at startup and held in
  `:persistent_term`. Lookups read directly from `:persistent_term` and bypass
  the GenServer mailbox entirely. This is the fastest backend on every
  benchmarked workload — and dramatically faster (≈18×) than any other
  backend on no-match queries (e.g. ocean points), where the previous
  bounding-box-scan algorithms had to walk every shape.

* `TzWorld.Backend.EtsWithIndexCache` keeps the timezone shapes in a
  compressed `:ets` table, with an in-memory cache of every bounding box for
  candidate filtering. Useful when you want shapes shared across processes
  via `:ets` rather than via `:persistent_term`.

* `TzWorld.Backend.DetsWithIndexCache` keeps the shapes on disk in a `:dets`
  file, with the same in-memory bounding-box cache. Useful when memory is
  constrained — only the index is kept in memory and shapes are loaded from
  disk on demand.

Other backends can be implemented as long as they follow the `TzWorld.Backend`
behaviour. Custom backends should be configured in `config.exs` or `runtime.exs`
under the `:default_backend` key so that they will be considered as the default
for calls to `TzWorld.timezone_at/1`. For example:

```elixir
config :tz_world,
  default_backend: MyTzWorldBackend
```

## Installing the Timezones Geo JSON data

Installing `tz_world` from source or from hex does not include the timezones
Geo JSON data. The data is required and to install or update it run:

```elixir
mix tz_world.update
```

This task will download, transform, zip and store the timezones Geo data. Depending on internet and computer speed this may take a few minutes.

By default `mix tz_world.update` will download geojson data that does *not* include time zone information for the oceans. The following optional flags configure its behaviour:

* `--include-oceans` (`-o`) will download the geojson data, including data for the oceans. This gives almost complete global coverage of time zone data. The default is `--no-include-oceans` which does not include data that covers the oceans. The geojson data including the oceans is about 10% larger than the data that does not include the oceans.

* `--force` (`-f`) does two things:
    * Forces an update even if the currently installed data is already at the latest release. Useful when switching between including and excluding ocean coverage.
    * Creates the directory configured under `:data_dir` if it does not yet exist. Without `--force` a missing `:data_dir` raises `File.Error` so that a misconfigured `:data_dir` is loud rather than silently materialised. Pass `--force` on the first install when you have set a custom `:data_dir` outside the build artifacts.

* `--trace` (`-t`) emits debug-level progress logs (current memory usage, download / extract / parse phases).

### Updating the Timezone data

From time-to-time the timezones Geo JSON data is updated in the [upstream project](https://github.com/evansiroky/timezone-boundary-builder/releases). The mix task `mix tz_world.update` will update the data if it is available.

A running application can also be instructed to reload the data by executing `TzWorld.reload_timezone_data`.

## Usage

The primary API is `TzWorld.timezone_at`. It takes either a `Geo.Point` struct or a `longitude` and `latitude` in degrees. Note the parameter order: `longitude`, `latitude`. It also takes and optional second parameter, `backend`, which must be one of the configured and running backend modules.  By default `timezone_at/2` will detect a running backend and will raise an exception if no running backend is found.

```elixir
iex> TzWorld.timezone_at(%Geo.Point{coordinates: {3.2, 45.32}})
{:ok, "Europe/Paris"}

iex> TzWorld.timezone_at({3.2, 45.32})
{:ok, "Europe/Paris"}

iex> TzWorld.timezone_at(%Geo.PointZ{coordinates: {-74.006, 40.7128, 0.0}})
{:ok, "America/New_York"}

# Assumes that the downloaded data does not include
# data for the oceans (the default)
iex> TzWorld.timezone_at(%Geo.Point{coordinates: {1.3, 65.62}})
{:error, :time_zone_not_found}
```

## Performance

Version 2.0 lookups are 1.4×–18× faster than 1.x (R-tree spatial index), and `mix tz_world.update` peak memory is ≈ 13× lower (end-to-end streaming pipeline). See the [Performance guide](https://hexdocs.pm/tz_world/performance.html) for measurements and methodology.
