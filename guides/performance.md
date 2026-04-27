# Performance

## Lookup speed (vs. 1.x)

Version 2.0 introduced an R-tree spatial index ([`TzWorld.Backend.SpatialIndex`](https://hexdocs.pm/tz_world/TzWorld.Backend.SpatialIndex.html)) that replaces the linear bounding-box scan used by every 1.x backend. Lookups are faster on every measured workload, with the largest wins on no-match queries (e.g. ocean points) where the previous algorithm had to walk every shape's bounding box. Speedups versus the 1.x backends, by input category:

| Input category      | Speedup vs. 1.x |
| ------------------- | --------------- |
| `ocean` (no-match)  | 18.2×           |
| `sparse_or_large`   | 1.64×           |
| `dense` (cities)    | 1.43×           |
| random uniform      | 1.42×           |
| `small_or_thin`     | 1.08×           |

Lookups also bypass the GenServer mailbox and read directly from `:persistent_term`, so they are lock-free under concurrent load and scale linearly with cores. Numbers above were collected with [`benchee/backend.exs`](https://github.com/kipcole9/tz_world/blob/v2.0.0/benchee/backend.exs) on the without-oceans dataset; reproduce locally with `mix run benchee/backend.exs`.

## `mix tz_world.update` memory (vs. 1.x)

Version 2.0 also rewrote the data-update pipeline to stream end-to-end. The source zip is downloaded straight to a temp file (no in-memory body), unzipped to disk (no in-memory JSON), parsed in 64 KiB chunks via OTP's built-in `:json` module with a feature-diverting decoder callback, and each `Geo.Polygon` / `Geo.MultiPolygon` is written to the on-disk index as it is decoded. The full GeoJSON is never resident in memory at any point.

Measured BEAM peak memory of `mix tz_world.update` on the without-oceans dataset (158 MB GeoJSON, 419 shapes, post-GC sampled):

| Version | Peak BEAM memory during update |
| ------- | ------------------------------ |
| 1.x     | ≈ 920 MB                       |
| 2.x     | ≈ 70 MB                        |

About a **13× reduction**. The 2.x peak is bounded by one in-flight feature's coordinate buffer plus the parser's per-chunk state, not by the dataset size — so the with-oceans dataset (~ 3× larger) lands at sub-300 MB peak in 2.x where 1.x peaked at multiple GB.

The on-disk format itself (`priv/timezones-geodata.tzw1`) is also incrementally consumable: backends stream shapes one at a time at startup rather than loading the full file into memory before iterating it. `TzWorld.Backend.DetsWithIndexCache` rebuild on update was reduced from O(all shapes resident) to O(one shape) for the same reason.
