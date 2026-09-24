# Performance

## Lookups, memory and load time (vs. 2.4)

Version 2.5 compiles every shape for point-in-polygon testing as the data is loaded ([`TzWorld.PackedGeometry`](https://hexdocs.pm/tz_world/TzWorld.PackedGeometry.html)). Each ring's vertices are packed into a binary at 16 bytes a vertex instead of 72, and its edges are indexed by the horizontal bands they span, so a test examines only the edges in the query point's band — a few dozen, even in rings of nearly 200,000 vertices — rather than every vertex of the ring. Results are unchanged, including which zone `TzWorld.timezone_at/1` reports where zones overlap: 2.4 and 2.5 agree on every one of 5,134 test points.

Measured on the without-oceans dataset with an 8-core, 16-thread Intel Xeon W-2140B running OTP 29.1 without the JIT. With the JIT, absolute times are likely to be shorter:

| Measure                              | 2.4                                     | 2.5    |
| ------------------------------------ | --------------------------------------- | ------ |
| `timezone_at/1`, mean over 20 cities | 15.4 ms                                 | 10 µs  |
| Memory after loading                 | 1.26 GB (530 MB once garbage collected) | 152 MB |
| Load at startup                      | 9.4 s                                   | 1.7 s  |
| Reload                               | 1.9–5.8 s                               | 1.7 s  |

In 2.4 the backend process decoded the shapes on its own heap before storing them, and held that garbage — about 730 MB — until it was next garbage collected, which for an idle backend can be a long time. How large that heap still was also decided how long a reload took. In 2.5 the shapes are decoded and compiled in short-lived tasks, so the memory used after loading is the data itself.

Those tasks run in parallel, so load time depends on the cores available: 8.2 s on one scheduler, 4.5 s on two and 2.5 s on four. On a single core a reload is slower than in 2.4, 8.2 s against 5.8 s, while loading at startup is still faster.

## Lookup speed (vs. 1.x)

Version 2.0 introduced an R-tree spatial index ([`TzWorld.Backend.SpatialIndex`](https://hexdocs.pm/tz_world/TzWorld.Backend.SpatialIndex.html)) that replaces the linear bounding-box scan used by every 1.x backend. Lookups are faster on every measured workload, with the largest wins on no-match queries (e.g. ocean points) where the previous algorithm had to walk every shape's bounding box. Speedups versus the 1.x backends, by input category:

| Input category      | Speedup vs. 1.x |
| ------------------- | --------------- |
| `ocean` (no-match)  | 18.2×           |
| `sparse_or_large`   | 1.64×           |
| `dense` (cities)    | 1.43×           |
| random uniform      | 1.42×           |
| `small_or_thin`     | 1.08×           |

Lookups also bypass the GenServer mailbox and read directly from `:persistent_term`, so they are lock-free under concurrent load and scale linearly with cores. Numbers above were collected with [`benchee/backend.exs`](https://github.com/kipcole9/tz_world/blob/v2.0.0/benchee/backend.exs) on the without-oceans dataset. To reproduce them locally, run `mix tz_world.update --backends dets` to build the cache the deprecated backends read, then `mix run benchee/backend.exs`.

## `mix tz_world.update` memory (vs. 1.x)

Version 2.0 also rewrote the data-update pipeline to stream end-to-end. The source zip is downloaded straight to a temp file (no in-memory body), unzipped to disk (no in-memory JSON), parsed in 64 KiB chunks via OTP's built-in `:json` module with a feature-diverting decoder callback, and each `Geo.Polygon` / `Geo.MultiPolygon` is written to the on-disk index as it is decoded. The full GeoJSON is never resident in memory at any point.

Measured BEAM peak memory of `mix tz_world.update` on the without-oceans dataset (158 MB GeoJSON, 419 shapes, post-GC sampled):

| Version | Peak BEAM memory during update |
| ------- | ------------------------------ |
| 1.x     | ≈ 920 MB                       |
| 2.x     | ≈ 70 MB                        |

About a **13× reduction**. The 2.x peak is bounded by one in-flight feature's coordinate buffer plus the parser's per-chunk state, not by the dataset size — so the with-oceans dataset (~ 3× larger) lands at sub-300 MB peak in 2.x where 1.x peaked at multiple GB.

The on-disk format itself (`priv/timezones-geodata.tzw1`) is also incrementally consumable: backends stream shapes one at a time at startup rather than loading the full file into memory before iterating it. `TzWorld.Backend.DetsWithIndexCache` rebuild on update was reduced from O(all shapes resident) to O(one shape) for the same reason.
