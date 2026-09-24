# TODO

Work tracking for `tz_world`. Longer design notes, where a task needs one,
live under `plans/`.

## Open

* [ ] **Remove the deprecated backends** — delete `TzWorld.Backend.DetsWithIndexCache`
  and `TzWorld.Backend.EtsWithIndexCache`, the `dets` and `ets` names accepted by
  `mix tz_world.update --backends`, and the `timezones-geodata.dets` cache they
  depend on. Deprecated in v2.4.0. Also drop them from `@reload_backends` and the
  backend-precedence list in `lib/tz_world.ex`, the backend list in `README.md`,
  and the rebuild note in `guides/performance.md`, plus the backend comparison
  in `benchee/backend.exs`. The test suite is already free of them.

* [ ] **Return errors from `TzWorld.Downloader.latest_release/2`** — it raises when the
  release list cannot be fetched, is empty, or lacks the expected asset, and
  `update_release/1` and `mix tz_world.update` inherit the raise. Returning
  `{:error, reason}` changes their return shapes, so it belongs in a minor release.

## Done

* [x] **Faster, smaller time zone lookups** — packed, band-indexed rings compiled in
  parallel at load: ~10 µs lookups in 152 MB, results unchanged. Plan in
  [plans/lookup-performance.md](plans/lookup-performance.md). 2026-09-24, v2.5.0.
