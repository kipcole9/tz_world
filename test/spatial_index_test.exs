defmodule TzWorld.SpatialIndexTest do
  use ExUnit.Case, async: false

  alias TzWorld.TimezoneFixtures

  # EtsWithIndexCache uses the same algorithm as the previous Memory
  # backend (linear bbox scan + per-shape ray cast) but stores data in
  # ETS. It serves as the independent reference against which the
  # SpatialIndex backend is validated.
  @reference TzWorld.Backend.EtsWithIndexCache

  setup_all do
    TzWorld.Backend.SpatialIndex.start_link()
    @reference.start_link()
    :ok
  end

  describe "fixture coverage" do
    for {lng, lat, expected, label} <- TimezoneFixtures.all() do
      expected_result =
        if expected, do: {:ok, expected}, else: {:error, :time_zone_not_found}

      test "SpatialIndex resolves #{label} → #{inspect(expected_result)}" do
        point = %Geo.Point{coordinates: {unquote(lng), unquote(lat)}}

        assert TzWorld.timezone_at(point, TzWorld.Backend.SpatialIndex) ==
                 unquote(Macro.escape(expected_result))
      end
    end
  end

  describe "agreement with reference backend" do
    test "agrees on every curated fixture" do
      for {lng, lat, _expected, label} <- TimezoneFixtures.all() do
        point = %Geo.Point{coordinates: {lng, lat}}
        reference = TzWorld.timezone_at(point, @reference)
        spatial = TzWorld.timezone_at(point, TzWorld.Backend.SpatialIndex)

        assert reference == spatial,
               "Disagreement at #{label} (#{lng}, #{lat}): " <>
                 "reference=#{inspect(reference)} SpatialIndex=#{inspect(spatial)}"
      end
    end

    test "agrees on 1000 random points (uniformly distributed over the globe)" do
      # Compare via `all_timezones_at` rather than `timezone_at`: where
      # multiple zones overlap (e.g. Xinjiang has both Asia/Urumqi and
      # Asia/Shanghai), `timezone_at` legitimately returns "the first
      # match" and the two backends iterate shapes in different orders.
      # The actual invariant we're verifying is that the spatial index
      # surfaces the same *set* of candidate zones.
      points = TimezoneFixtures.random_points(1000)

      # Compare as sets (uniq + sort): the reference backends emit the
      # same `tzid` more than once for a MultiPolygon with several
      # sub-polygons whose bboxes overlap the point. SpatialIndex
      # dedupes by construction. Set equality is the right invariant.
      mismatches =
        for {lng, lat} <- points,
            point = %Geo.Point{coordinates: {lng, lat}},
            {:ok, reference} = TzWorld.all_timezones_at(point, @reference),
            {:ok, spatial} = TzWorld.all_timezones_at(point, TzWorld.Backend.SpatialIndex),
            reference_set = reference |> Enum.uniq() |> Enum.sort(),
            spatial_set = spatial |> Enum.uniq() |> Enum.sort(),
            reference_set != spatial_set do
          {lng, lat, reference_set, spatial_set}
        end

      assert mismatches == [],
             "#{length(mismatches)} mismatch(es). First: #{inspect(Enum.take(mismatches, 3))}"
    end

    test "all_timezones_at agrees on every curated fixture" do
      for {lng, lat, _expected, label} <- TimezoneFixtures.all() do
        point = %Geo.Point{coordinates: {lng, lat}}
        {:ok, reference} = TzWorld.all_timezones_at(point, @reference)
        {:ok, spatial} = TzWorld.all_timezones_at(point, TzWorld.Backend.SpatialIndex)

        assert Enum.sort(reference) == Enum.sort(spatial),
               "Disagreement at #{label}: " <>
                 "reference=#{inspect(reference)} SpatialIndex=#{inspect(spatial)}"
      end
    end
  end
end
