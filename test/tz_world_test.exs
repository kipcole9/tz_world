defmodule TzWorldTest do
  use ExUnit.Case
  doctest TzWorld

  # SpatialIndex is the only supported backend; the DETS and ETS backends
  # are deprecated and removed in the next release.
  @backends [
    TzWorld.Backend.SpatialIndex
  ]

  setup_all do
    for backend <- @backends do
      backend.start_link()
    end

    :ok
  end

  for backend <- @backends do
    test "a known lookup with backend #{backend}" do
      assert TzWorld.timezone_at(%Geo.Point{coordinates: {3.2, 45.32}}, unquote(backend)) ==
               {:ok, "Europe/Paris"}
    end

    test "a known lookup failure with backend #{backend}" do
      assert TzWorld.timezone_at(%Geo.Point{coordinates: {1.3, 65.62}}, unquote(backend)) ==
               {:error, :time_zone_not_found}
    end

    test "an eastern lon, northern lat with backend #{backend}" do
      assert TzWorld.timezone_at(%Geo.Point{coordinates: {103.8198, 1.3521}}, unquote(backend)) ==
               {:ok, "Asia/Singapore"}
    end

    test "an Russian timezone with known issue in other libraries with backend #{backend}" do
      assert TzWorld.timezone_at(%Geo.Point{coordinates: {85.95926, 51.95874}}, unquote(backend)) ==
               {:ok, "Asia/Barnaul"}
    end

    test "a western lon, northern lat with GeoPointZ with backend #{backend}" do
      assert TzWorld.timezone_at(
               %Geo.PointZ{coordinates: {-74.006, 40.7128, 0.0}},
               unquote(backend)
             ) ==
               {:ok, "America/New_York"}
    end
  end

  describe "invalid points" do
    @invalid_points [
      nil,
      "",
      :"",
      42,
      [],
      %{},
      {nil, nil},
      {"3.2", "45.32"},
      {:a, :b},
      {1, 2, 3},
      {180.5, 0},
      {0, -90.5},
      {500, 500},
      %Geo.Point{coordinates: nil},
      %Geo.Point{coordinates: {"3.2", 45.32}},
      %Geo.Point{coordinates: {3.2, nil}},
      %Geo.Point{coordinates: {500.0, 0.0}},
      %Geo.Point{coordinates: {3.2, 45.32, 0.0}},
      %Geo.PointZ{coordinates: nil},
      %Geo.PointZ{coordinates: {3.2, 45.32}},
      %Geo.PointZ{coordinates: {3.2, 100.0, 0.0}},
      %Geo.Polygon{coordinates: []}
    ]

    test "return an error from timezone_at/2 rather than raising" do
      for point <- @invalid_points do
        assert TzWorld.timezone_at(point, TzWorld.Backend.SpatialIndex) ==
                 {:error, :invalid_point},
               "point: #{inspect(point)}"
      end
    end

    test "return an error from all_timezones_at/2 rather than raising" do
      for point <- @invalid_points do
        assert TzWorld.all_timezones_at(point, TzWorld.Backend.SpatialIndex) ==
                 {:error, :invalid_point},
               "point: #{inspect(point)}"
      end
    end

    test "do not include points on the boundaries of the coordinate range" do
      for point <- [{-180, -90}, {180, 90}, {-180.0, 90.0}, {180.0, -90.0}] do
        assert {:ok, _} = TzWorld.all_timezones_at(point, TzWorld.Backend.SpatialIndex)
      end
    end
  end
end
