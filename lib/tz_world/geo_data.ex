defmodule TzWorld.GeoData do
  @moduledoc false

  @compressed_data_file "timezones-geodata.etf.zip"
  @etf_data_file "timezones-geodata.etf"
  @osm_srid 3857

  defdelegate version, to: TzWorld
  import TzWorld, only: [maybe_log: 2]

  def default_data_dir do
    TzWorld.app_name()
    |> :code.priv_dir()
    |> List.to_string()
  end

  def data_dir do
    Application.get_env(TzWorld.app_name(), :data_dir, default_data_dir())
  end

  def compressed_data_path do
    data_dir()
    |> Path.join(@compressed_data_file)
    |> to_charlist
  end

  # The archive entry name. We deliberately store the file with a bare
  # name (no directory component) so `:zip.unzip/2` does not warn about
  # absolute paths and so the archive is portable. The contents are
  # always extracted to memory, so the entry name is purely cosmetic.
  def etf_data_path do
    to_charlist(@etf_data_file)
  end

  def generate_compressed_data(source_data, version, trace? \\ false)
      when is_list(source_data) or is_binary(source_data) do
    maybe_log("Transforming source data", trace?)
    binary_data = transform_source_data(source_data, version)
    maybe_log("Transformed source data", trace?)
    :erlang.garbage_collect()
    :zip.zip(compressed_data_path(), [{etf_data_path(), binary_data}])
    maybe_log("Compressed data into a zip file", trace?)
  end

  def load_compressed_data do
    with {:ok, [{_, terms} | _rest]} <- :zip.unzip(compressed_data_path(), [:memory]) do
      {:ok, :erlang.binary_to_term(terms)}
    end
  end

  def transform_source_data(source_data, version) when is_list(source_data) do
    source_data
    |> :erlang.list_to_binary()
    |> transform_source_data(version)
  end

  def transform_source_data(source_data, version) when is_binary(source_data) do
    case :zip.unzip(source_data, [:memory]) do
      {:ok, [{_, json} | _rest]} ->
        json
        |> decode_json(version)
        |> :erlang.term_to_binary()

      error ->
        raise RuntimeError, "Unable to unzip downloaded data. Error: #{inspect(error)}"
    end
  end

  # Streaming GeoJSON decode. Each Feature is converted to a Geo struct
  # (with bounding box) the moment it finishes parsing, then handed to the
  # parser as the value for that array slot. The full parsed JSON map is
  # never materialized: at peak we hold only the accumulated list of Geo
  # structs plus whatever object is currently being built.
  defp decode_json(json, version) do
    decoders = %{object_finish: &json_object_finish/2}
    {%{"features" => shapes}, :ok, ""} = :json.decode(json, :ok, decoders)
    [version | shapes]
  end

  defp json_object_finish(pairs, acc) do
    map = :maps.from_list(pairs)

    case map do
      %{"type" => "Feature", "properties" => properties, "geometry" => geometry} ->
        {build_shape(geometry, normalize_properties(properties)), acc}

      other ->
        {other, acc}
    end
  end

  defp normalize_properties(properties) do
    Enum.into(properties, %{}, fn
      {"tzid", v} -> {:tzid, v}
      other -> other
    end)
  end

  defp build_shape(%{"type" => "Polygon", "coordinates" => rings}, properties) do
    coordinates = Enum.map(rings, &ring_to_tuples/1)
    [outer | _holes] = coordinates

    %Geo.Polygon{
      coordinates: coordinates,
      srid: @osm_srid,
      properties: Map.put(properties, :bounding_box, ring_bounding_box(outer))
    }
  end

  defp build_shape(%{"type" => "MultiPolygon", "coordinates" => polygons}, properties) do
    coordinates = Enum.map(polygons, fn rings -> Enum.map(rings, &ring_to_tuples/1) end)
    bounding_boxes = Enum.map(coordinates, fn [outer | _] -> ring_bounding_box(outer) end)

    %Geo.MultiPolygon{
      coordinates: coordinates,
      srid: @osm_srid,
      properties: Map.put(properties, :bounding_box, bounding_boxes)
    }
  end

  defp ring_to_tuples(ring) do
    Enum.map(ring, fn [x, y] -> {x, y} end)
  end

  defp ring_bounding_box(ring) do
    [{x_min, y_min}, {x_max, y_max}] =
      Enum.reduce(ring, [{180, 90}, {-180, -90}], fn
        {x, y}, [{x_min_a, y_min_a}, {x_max_a, y_max_a}] ->
          [{min(x, x_min_a), min(y, y_min_a)}, {max(x, x_max_a), max(y, y_max_a)}]
      end)

    %Geo.Polygon{
      coordinates: [[{x_min, y_max}, {x_min, y_min}, {x_max, y_min}, {x_max, y_max}]],
      srid: @osm_srid
    }
  end
end
