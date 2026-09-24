# Lookup performance

**Status:** implemented (v2.5.0), 2026-09-24

A time zone lookup cost 10–50 ms for large zones and the shape data held 530 MB of
`:persistent_term`. Almost all of both went on point-in-polygon work that cannot
affect the answer. This plan made lookups three orders of magnitude faster and cut
memory by more than two thirds, without changing a single result.

## Problem

`TzWorld.Backend.SpatialIndex` narrows a query to candidate shapes with an R-tree,
then calls `TzWorld.contains?/2` on each. Profiling lookups shows the R-tree takes
0.1% of the time and point-in-polygon ray casting takes 99.5%:

* **~57%** is `interior?/2` building a translated copy of the entire ring
  (`for {x, y} <- ring, do: {x - px, y - py}`) before any crossing is tested.

* **~43%** is `count_crossing/1`, which is body-recursive — one stack frame per
  vertex — and re-conses a list cell at every step.

* A MultiPolygon's sub-polygons are all ray-cast in turn, with no bounding-box
  check, although the R-tree has already matched one sub-polygon's box.

Nearly all of that work is wasted. A horizontal ray can only be crossed by an edge
whose y-extent contains the point's y, and there are very few such edges:

| Point | Vertices processed | Edges that can cross the ray |
|---|---|---|
| Moscow | 144,137 | 8 |
| Sydney | 73,428 | 2 |
| Denver | 40,440 | 2 |
| Jakarta | 520 | 2 |

The shapes are held as lists of `{x, y}` tuples of boxed floats: 9 words per vertex,
530 MB for the 7.7 million vertices in the dataset.

## Options

* **Constant-factor rewrite** of `interior?/2` and `count_crossing/1` as one
  tail-recursive pass that translates each vertex as it is read. Measured 1.6x
  faster, identical on all 68 rings tested. Small and independent.

* **Sub-polygon bounding-box rejection.** Skip any sub-polygon whose box excludes
  the point. Measured 3.2x for Tokyo and 1.7x for Athens; no effect on
  single-ring zones.

* **Y-banded edge index over packed geometry.** Store each ring as a binary of
  float pairs, and index its edges by the horizontal bands their y-extent
  overlaps; a query tests only its own band. Prototyped with 512 bands on the
  three largest rings: 527–694x faster, identical on 400 probes each. Packed
  vertices take 16 bytes instead of 72, so memory falls from 530 MB to ~156 MB.

* **Parallel compilation at load.** Compiling the packed form is CPU work per
  shape, and shapes are independent, so it can run one task per shape.

* **Lookup cache.** Makes repeated lookups of one point free, but an unbounded
  cache is a memory hazard in a library; once lookups are microseconds it is
  unnecessary. Callers with fixed locations can memoise.

* **Polygon simplification.** Rejected: it changes answers near borders, and with
  a band index vertex count no longer affects query time.

## Decision

Adopt the constant-factor rewrite, bounding-box rejection, the banded index and
parallel compilation.

* **Results must be identical,** including which zone `timezone_at/1` returns where
  zones overlap ("the first match"). Verified against a baseline of 5,134 points —
  5,000 seeded random, the curated fixtures and a grid over Xinjiang — 57 of which
  fall in overlapping zones.

* **The R-tree and its shape-level leaf ids stay,** so candidates are visited in the
  same order and within a MultiPolygon sub-polygons are tried in the same order.
  Bounding-box rejection cannot change which sub-polygon first contains a point.

* **The banded index is exact.** An edge can only cross the ray at y if its y-extent
  contains y, and every such edge is placed in y's band, because band assignment is
  monotonic in y.

* **Bounding-box rejection uses three sides of the box.** A ray from a point above,
  below or to the right of a ring crosses none of its edges, whatever the ring and
  in floating point too. Rejecting points to the left would rely on rings being
  closed, and on the ray cast's arithmetic not underflowing, and measured no faster,
  so those points are ray cast.

* **Shapes are decoded and compiled in parallel,** one task per shape, and collected
  in file order, the order the R-tree entries have always been built in. The tasks
  also keep the decoded Geo structs off the backend process's heap.

* **The SpatialIndex backend stops holding Geo structs.** That is where the memory
  saving comes from. `TzWorld.contains?/2` keeps its Geo-struct interface for the
  deprecated backends and the test oracle, with the constant-factor rewrite inside.

* **The `.tzw1` format is unchanged.** Packing and indexing happen at load.

* **Band count adapts to the ring,** keeping roughly a fixed number of edges per band.

## Results

Measured on the without-oceans dataset with an 8-core, 16-thread Intel Xeon W-2140B,
against d7a71d3:

| Measure | Before | After |
|---|---|---|
| `timezone_at/1`, mean over 20 cities | 15.37 ms | 10 µs |
| `all_timezones_at/1`, mean over 20 cities | — | 13 µs |
| Memory after loading, forced GC | 530.5 MB | 152.4 MB |
| Memory after loading, no forced GC | 1,258.5 MB | 154.3 MB |
| Load at startup | 9.4 s | 1.7 s |
| Reload | 1.9–5.8 s | 1.7 s |

Before, the backend process decoded every shape on its own heap and kept about
730 MB of garbage there until it was next collected; how large that heap still was
decided the reload time. Load time now scales with schedulers: 8.2 s on one, 4.5 s
on two, 2.5 s on four. On one scheduler a reload is slower than before (8.2 s
against 5.8 s), so the reload timeout was raised from 30 s to 120 s.

## Tasks

* [x] **Constant-factor rewrite of `contains?/2`** — single tail-recursive pass, no
  translated ring copy.

* [x] **Packed, banded rings in the SpatialIndex backend** — with sub-polygon
  bounding-box rejection, preserving candidate and sub-polygon order.

* [x] **Parallel load** — decode and compile shapes in tasks, collected in file order.

* [x] **Verify** — the 5,134-point baseline identical; the differential test suite
  green; unit tests of `TzWorld.PackedGeometry` against the ray cast on synthetic,
  degenerate and unclosed rings; memory, load time and lookup cost measured.

* [x] **Document** — CHANGELOG, the performance guide, and the memory profile in the
  SpatialIndex moduledoc.

### Deferred

* [ ] **Store the packed form in `.tzw1`** — would remove the compile from load
  entirely. Worth reviving only if load time on single-core machines matters.
