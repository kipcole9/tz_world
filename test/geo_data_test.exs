defmodule TzWorld.GeoDataTest do
  use ExUnit.Case, async: false

  # Minimal valid GeoJSON FeatureCollection with a single polygon.
  # Enough to exercise the streaming JSON parser and the on-disk
  # write path end-to-end.
  @sample_geojson """
  {
    "type": "FeatureCollection",
    "features": [
      {
        "type": "Feature",
        "properties": {"tzid": "Etc/UTC"},
        "geometry": {
          "type": "Polygon",
          "coordinates": [[[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [0.0, 0.0]]]
        }
      }
    ]
  }
  """

  describe "generate_compressed_data/4" do
    test "with force?=true, creates the configured :data_dir if it does not exist" do
      missing_dir = fresh_missing_dir()
      source_zip = build_source_zip(@sample_geojson)

      with_data_dir(missing_dir, fn ->
        try do
          assert :ok =
                   TzWorld.GeoData.generate_compressed_data(
                     source_zip,
                     "test-version",
                     false,
                     true
                   )

          assert File.exists?(Path.join(missing_dir, "timezones-geodata.tzw1"))
        after
          File.rm_rf!(missing_dir)
          File.rm!(source_zip)
        end
      end)
    end

    test "with force?=false (default), refuses to create a missing :data_dir" do
      # The pre-2.1.x default was to crash with File.Error when
      # :data_dir did not exist. We preserve that behaviour without
      # `force?` so misconfigured :data_dir values surface loudly
      # rather than be silently materialised.
      missing_dir = fresh_missing_dir()
      source_zip = build_source_zip(@sample_geojson)

      with_data_dir(missing_dir, fn ->
        try do
          assert_raise File.Error, fn ->
            TzWorld.GeoData.generate_compressed_data(source_zip, "test-version")
          end

          refute File.exists?(missing_dir)
        after
          File.rm_rf!(missing_dir)
          File.rm!(source_zip)
        end
      end)
    end
  end

  defp fresh_missing_dir do
    dir = Path.join(System.tmp_dir!(), "tz_world_missing_#{:erlang.unique_integer([:positive])}")

    refute File.exists?(dir), "precondition: #{dir} should not exist"
    dir
  end

  defp with_data_dir(dir, fun) do
    previous = Application.get_env(:tz_world, :data_dir)

    try do
      Application.put_env(:tz_world, :data_dir, dir)
      fun.()
    after
      if previous,
        do: Application.put_env(:tz_world, :data_dir, previous),
        else: Application.delete_env(:tz_world, :data_dir)
    end
  end

  defp build_source_zip(json) do
    tmp = System.tmp_dir!()
    zip_path = Path.join(tmp, "tz_world_src_#{:erlang.unique_integer([:positive])}.zip")

    {:ok, _} =
      :zip.zip(String.to_charlist(zip_path), [{~c"timezones.geojson", json}])

    zip_path
  end
end
