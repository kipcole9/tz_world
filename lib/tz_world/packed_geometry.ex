defmodule TzWorld.PackedGeometry do
  @moduledoc """
  Time zone shapes compiled for fast, exact point-in-polygon tests.

  The shapes in the timezone data are lists of `{x, y}` tuples holding boxed
  floats: nine words per vertex, and a point-in-polygon test that walks every
  vertex of a ring. Some rings have more than 190,000 vertices, yet a
  horizontal ray through a point can only be crossed by the handful of edges
  whose vertical extent contains the point. This module compiles each shape so
  a test visits little more than those edges.

  ### Representation

  A compiled shape is `{tzid, polygons}`, with the polygons in the shape's own
  order. Each polygon is `{outer, holes}`, and each ring is packed as:

  * the vertical extent and right-hand side of its bounding box, used to reject
    points whose ray cannot cross it;

  * its vertices, as native 64-bit float pairs in a single binary — 16 bytes a
    vertex rather than 72;

  * its edges indexed by the horizontal bands their vertical extent overlaps, in
    compressed sparse row form: one binary of 32-bit edge indices laid out band
    by band, and one binary of per-band start offsets.

  The number of bands grows with the ring, so each band holds roughly the same
  number of edges however large the ring is.

  ### Exactness

  Results are identical to ray casting over every vertex of the original
  shapes. The crossing test is the same even-odd rule, applied to the same
  translated coordinates in the same arithmetic, and vertices round-trip
  through the binary unchanged. Only work that cannot change the answer is
  skipped:

  * an edge crosses the ray at `y` only if its vertical extent contains `y`, and
    every such edge is placed in `y`'s band, because assigning bands is
    monotonic in `y`;

  * a ray from a point above, below or to the right of a ring's bounding box
    crosses none of its edges. Points to the left are left to the ray cast:
    rejecting them too would rely on the ring being closed.

  """

  @edges_per_band 32

  @compile {:inline, band_of: 4}

  # Band and edge are packed into one integer so that grouping edges by band is
  # a native sort of integers.
  @edge_space 4_294_967_296

  # An empty ring contains no point, as with `TzWorld.contains?/2`. Its vertical
  # extent is inverted, so every point is rejected before anything else is read.
  @empty_ring {0.0, 1.0, 0.0, 0.0, 1, <<>>, <<>>, <<0::32, 0::32>>}

  @typedoc "A compiled ring: bounds, band scaling, and three binaries."
  @type ring ::
          {number(), number(), number(), float(), pos_integer(), binary(), binary(), binary()}

  @typedoc "A compiled polygon: its outer ring and any holes."
  @type polygon :: {ring(), [ring()]}

  @doc """
  Compiles a time zone shape.

  ### Arguments

  * `shape` is a `Geo.MultiPolygon` or `Geo.Polygon` whose properties carry the
    `:tzid`.

  ### Returns

  * `{tzid, polygons}`, with the polygons in the same order as the shape's.

  ### Examples

      iex> square = %Geo.Polygon{
      ...>   coordinates: [[{0.0, 0.0}, {4.0, 0.0}, {4.0, 4.0}, {0.0, 4.0}, {0.0, 0.0}]],
      ...>   properties: %{tzid: "Etc/Square"}
      ...> }
      iex> {tzid, [{_outer, holes}]} = TzWorld.PackedGeometry.compile(square)
      iex> {tzid, holes}
      {"Etc/Square", []}

  """
  @spec compile(Geo.MultiPolygon.t() | Geo.Polygon.t()) :: {String.t(), [polygon()]}
  def compile(shape)

  def compile(%Geo.MultiPolygon{coordinates: polygons, properties: %{tzid: tzid}}),
    do: {tzid, Enum.map(polygons, &compile_polygon/1)}

  def compile(%Geo.Polygon{coordinates: rings, properties: %{tzid: tzid}}),
    do: {tzid, [compile_polygon(rings)]}

  @doc """
  Returns whether any of a compiled shape's polygons contains a point.

  A polygon contains the point when its outer ring does and none of its holes
  do. Polygons are tried in order and the first to contain the point ends the
  search.

  ### Arguments

  * `polygons` is the polygon list of a compiled shape.

  * `x` and `y` are the point's longitude and latitude.

  ### Returns

  * `true` or `false`.

  ### Examples

      iex> square_with_hole = %Geo.Polygon{
      ...>   coordinates: [
      ...>     [{0.0, 0.0}, {4.0, 0.0}, {4.0, 4.0}, {0.0, 4.0}, {0.0, 0.0}],
      ...>     [{1.0, 1.0}, {2.0, 1.0}, {2.0, 2.0}, {1.0, 2.0}, {1.0, 1.0}]
      ...>   ],
      ...>   properties: %{tzid: "Etc/Square"}
      ...> }
      iex> {_tzid, polygons} = TzWorld.PackedGeometry.compile(square_with_hole)
      iex> TzWorld.PackedGeometry.contains?(polygons, 3.0, 3.0)
      true
      iex> TzWorld.PackedGeometry.contains?(polygons, 1.5, 1.5)
      false

  """
  @spec contains?([polygon()], number(), number()) :: boolean()
  def contains?(polygons, x, y)

  def contains?([], _x, _y), do: false

  def contains?([{outer, holes} | rest], x, y) do
    (ring_contains?(outer, x, y) and not any_ring_contains?(holes, x, y)) or
      contains?(rest, x, y)
  end

  # --- Compilation

  defp compile_polygon([outer | holes]),
    do: {compile_ring(outer), Enum.map(holes, &compile_ring/1)}

  defp compile_polygon([]), do: {@empty_ring, []}

  defp compile_ring([]), do: @empty_ring

  defp compile_ring(ring) do
    {xmax, ymin, ymax, vertices} = pack(ring)
    edge_count = length(ring) - 1

    {bands, scale} =
      if ymax > ymin do
        bands = max(1, div(edge_count, @edges_per_band))
        {bands, bands / (ymax - ymin)}
      else
        {1, 0.0}
      end

    keys = edge_keys(ring, 0, ymin, scale, bands, [])
    {edges, offsets} = band_table(:lists.sort(keys), 0, 0, bands, <<>>, <<>>)
    {xmax, ymin, ymax, scale, bands, vertices, edges, offsets}
  end

  # The bounds and the packed vertices in one pass. Appending to the binary in
  # a loop lets the runtime grow it in place.
  defp pack([{x, y} | rest]),
    do: pack(rest, x, y, y, <<x::float-native-64, y::float-native-64>>)

  defp pack([], xmax, ymin, ymax, vertices), do: {xmax, ymin, ymax, vertices}

  defp pack([{x, y} | rest], xmax, ymin, ymax, vertices) do
    pack(
      rest,
      max(x, xmax),
      min(y, ymin),
      max(y, ymax),
      <<vertices::binary, x::float-native-64, y::float-native-64>>
    )
  end

  # One key per band each edge's vertical extent overlaps. Edge `i` joins
  # vertices `i` and `i + 1`, exactly the pairs the ray cast has always used.
  defp edge_keys([{_, ay} | [{_, by} | _] = tail], edge, ymin, scale, bands, keys) do
    low = band_of(min(ay, by), ymin, scale, bands)
    high = band_of(max(ay, by), ymin, scale, bands)
    edge_keys(tail, edge + 1, ymin, scale, bands, band_keys(low, high, edge, keys))
  end

  defp edge_keys(_ring, _edge, _ymin, _scale, _bands, keys), do: keys

  defp band_keys(band, high, _edge, keys) when band > high, do: keys

  defp band_keys(band, high, edge, keys),
    do: band_keys(band + 1, high, edge, [band * @edge_space + edge | keys])

  # Walks the band-sorted keys, emitting each edge index and, per band, the
  # position its edges start at. `offsets` ends with one entry per band plus a
  # final one, so band `b`'s edges run from `offsets[b]` to `offsets[b + 1]`.
  defp band_table([], next_band, position, bands, edges, offsets),
    do: {edges, emit_offsets(next_band, bands, position, offsets)}

  defp band_table([key | rest], next_band, position, bands, edges, offsets) do
    band = div(key, @edge_space)
    edge = rem(key, @edge_space)
    offsets = emit_offsets(next_band, band, position, offsets)
    edges = <<edges::binary, edge::native-32>>
    band_table(rest, max(next_band, band + 1), position + 1, bands, edges, offsets)
  end

  defp emit_offsets(from, to, _position, offsets) when from > to, do: offsets

  defp emit_offsets(from, to, position, offsets),
    do: emit_offsets(from + 1, to, position, <<offsets::binary, position::native-32>>)

  # Monotonic in `y`, which is what makes band membership exact. Used both to
  # place edges and to choose the band a query reads.
  defp band_of(y, ymin, scale, bands) do
    band = trunc((y - ymin) * scale)
    if band >= bands, do: bands - 1, else: band
  end

  # --- Queries

  defp any_ring_contains?([], _x, _y), do: false

  defp any_ring_contains?([ring | rest], x, y),
    do: ring_contains?(ring, x, y) or any_ring_contains?(rest, x, y)

  # A ray from a point above, below or to the right of the ring crosses none of
  # its edges, so the point is rejected without reading them.
  defp ring_contains?({xmax, ymin, ymax, scale, bands, vertices, edges, offsets}, x, y) do
    if x > xmax or y < ymin or y > ymax do
      false
    else
      band = band_of(y, ymin, scale, bands)
      first = offset_at(offsets, band)
      count = offset_at(offsets, band + 1) - first
      start = first * 4
      length = count * 4
      <<_::binary-size(^start), band_edges::binary-size(^length), _::binary>> = edges
      rem(crossings(band_edges, vertices, x, y, 0), 2) == 1
    end
  end

  defp offset_at(offsets, band) do
    skip = band * 4
    <<_::binary-size(^skip), offset::native-32, _::binary>> = offsets
    offset
  end

  # The even-odd crossing test, unchanged from `TzWorld.contains?/2`: each
  # edge's endpoints are translated relative to the point and the ray runs
  # towards +x.
  defp crossings(<<edge::native-32, rest::binary>>, vertices, px, py, count) do
    skip = edge * 16

    <<_::binary-size(^skip), ax0::float-native-64, ay0::float-native-64, bx0::float-native-64,
      by0::float-native-64, _::binary>> = vertices

    ax = ax0 - px
    ay = ay0 - py
    bx = bx0 - px
    by = by0 - py

    count =
      if ay > 0 != by > 0 && (ax * by - bx * ay) / (by - ay) > 0 do
        count + 1
      else
        count
      end

    crossings(rest, vertices, px, py, count)
  end

  defp crossings(<<>>, _vertices, _px, _py, count), do: count
end
