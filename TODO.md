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
