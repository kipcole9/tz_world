defmodule TzWorld.PackedGeometryTest do
  use ExUnit.Case, async: true

  alias TzWorld.PackedGeometry

  doctest TzWorld.PackedGeometry

  # `TzWorld.contains?/2` ray casts over every vertex of the original shape. It
  # is the reference: the compiled shape must give the same answer for every
  # point, including points on vertices, on edges and on band boundaries.
  defp disagreements(shape, points) do
    {_tzid, polygons} = PackedGeometry.compile(shape)

    Enum.reject(points, fn {x, y} = point ->
      PackedGeometry.contains?(polygons, x, y) ==
        TzWorld.contains?(shape, %Geo.Point{coordinates: point})
    end)
  end

  defp polygon(rings), do: %Geo.Polygon{coordinates: rings, properties: %{tzid: "Test/Zone"}}

  defp multi_polygon(polygons),
    do: %Geo.MultiPolygon{coordinates: polygons, properties: %{tzid: "Test/Zone"}}

  # A closed, simple, star-shaped ring around `{x, y}`: vertices at increasing
  # angles, each at a random radius between `inner` and `outer`.
  defp star(x, y, inner, outer, vertex_count) do
    ring =
      for step <- 0..(vertex_count - 1) do
        angle = 2 * :math.pi() * step / vertex_count
        radius = inner + :rand.uniform() * (outer - inner)
        {x + radius * :math.cos(angle), y + radius * :math.sin(angle)}
      end

    ring ++ [hd(ring)]
  end

  # A closed staircase on the integer grid, so that many edges are horizontal and
  # many vertices share a latitude. With 80 steps the ring has 162 edges in five
  # bands, whose boundaries fall exactly on the vertex latitudes 16, 32, 48, 64.
  defp staircase(steps) do
    stairs =
      Enum.flat_map(1..steps, fn step -> [{steps - step + 1, step}, {steps - step, step}] end)

    ring = [{0, 0}, {steps, 0} | stairs] ++ [{0, 0}]
    Enum.map(ring, fn {x, y} -> {x * 1.0, y * 1.0} end)
  end

  defp probes(rings, count) do
    vertices = Enum.concat(rings)
    {xs, ys} = Enum.unzip(vertices)
    {xmin, xmax} = Enum.min_max(xs)
    {ymin, ymax} = Enum.min_max(ys)
    width = xmax - xmin
    height = ymax - ymin

    random =
      for _ <- 1..count do
        {xmin - 0.1 * width + :rand.uniform() * 1.2 * width,
         ymin - 0.1 * height + :rand.uniform() * 1.2 * height}
      end

    on_vertex_latitudes = for {_x, y} <- vertices, do: {xmin + :rand.uniform() * width, y}

    midpoints =
      for ring <- rings, [{ax, ay}, {bx, by}] <- Enum.chunk_every(ring, 2, 1, :discard) do
        {(ax + bx) / 2, (ay + by) / 2}
      end

    random ++ vertices ++ on_vertex_latitudes ++ midpoints
  end

  describe "agrees with TzWorld.contains?/2" do
    test "on a large star-shaped polygon with a hole" do
      :rand.seed(:exsss, {1, 2, 3})
      rings = [star(10.0, -20.0, 5.0, 10.0, 1_000), star(10.0, -20.0, 1.0, 3.0, 200)]

      assert disagreements(polygon(rings), probes(rings, 3_000)) == []
    end

    test "on a multi-polygon, including polygons with and without holes" do
      :rand.seed(:exsss, {4, 5, 6})

      polygons = [
        [star(-170.0, 60.0, 2.0, 4.0, 400)],
        [star(-160.0, 60.0, 2.0, 5.0, 700), star(-160.0, 60.0, 0.5, 1.5, 90)],
        [star(-150.0, 62.0, 1.0, 2.0, 40)]
      ]

      assert disagreements(multi_polygon(polygons), probes(Enum.concat(polygons), 3_000)) == []
    end

    test "on a staircase, probed on every grid line and in every cell" do
      ring = staircase(80)

      points =
        for x <- -1..81,
            y <- -1..81,
            {dx, dy} <- [{0.0, 0.0}, {0.5, 0.0}, {0.5, 0.5}],
            do: {x + dx, y + dy}

      assert disagreements(polygon([ring]), points) == []
    end

    test "with integer coordinates in the shape and the point" do
      ring = [{0, 0}, {10, 0}, {10, 10}, {0, 10}, {0, 0}]
      points = for x <- -1..11, y <- -1..11, do: {x, y}

      assert disagreements(polygon([ring]), points) == []
    end

    test "on degenerate and unclosed rings" do
      points = for x <- -1..3, y <- -1..3, do: {x * 1.0, y * 1.0}

      for ring <- [
            [],
            [{1.0, 1.0}],
            [{0.0, 0.0}, {2.0, 2.0}],
            [{0.0, 1.0}, {2.0, 1.0}, {0.0, 1.0}],
            [{0.0, 0.0}, {2.0, 2.0}, {0.0, 0.0}]
          ] do
        assert disagreements(polygon([ring]), points) == [], "ring: #{inspect(ring)}"
      end
    end

    test "on an unclosed ring, including points to the left of it" do
      :rand.seed(:exsss, {7, 8, 9})
      ring = Enum.drop(star(0.0, 0.0, 1.0, 2.0, 300), -1)
      left = for {_x, y} <- ring, dy <- [-0.001, 0.0, 0.001], do: {-3.0, y + dy}

      assert disagreements(polygon([ring]), probes([ring], 2_000) ++ left) == []
    end
  end

  describe "contains nothing" do
    test "for a polygon without rings" do
      {"Test/Zone", polygons} = PackedGeometry.compile(polygon([]))

      refute PackedGeometry.contains?(polygons, 0.0, 0.0)
    end

    test "for a multi-polygon without polygons" do
      {"Test/Zone", polygons} = PackedGeometry.compile(multi_polygon([]))

      refute PackedGeometry.contains?(polygons, 0.0, 0.0)
    end
  end
end
