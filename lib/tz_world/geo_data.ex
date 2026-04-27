defmodule TzWorld.GeoData do
  @moduledoc false

  @compressed_data_file "timezones-geodata.tzw1"
  @osm_srid 3857

  # On-disk format ("TZW1"): a gzip-compressed file containing
  #
  #   <<"TZW1">>                                            (4-byte magic)
  #   <<vsize::16, version::binary-size(vsize)>>            (data version)
  #   N times: <<rsize::32, term_to_binary(shape)::binary>> (shape records)
  #   EOF
  #
  # The producer streams one shape at a time during JSON parsing; the
  # reader yields shapes as a Stream. Neither side ever materializes
  # the full shape list in memory.
  @magic "TZW1"

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
    |> to_charlist()
  end

  @doc """
  Transform a downloaded GeoJSON zip into the on-disk TZW1 file.

  Each Feature is stream-decoded, converted to a `Geo.Polygon` /
  `Geo.MultiPolygon` struct (with bounding box), and written to disk
  immediately. Memory stays O(one shape) for the parse/transform/write
  pipeline.
  """
  def generate_compressed_data(source_data, version, trace? \\ false)
      when is_list(source_data) or is_binary(source_data) do
    maybe_log("Transforming source data", trace?)
    count = transform_source_data(source_data, version)
    maybe_log("Wrote #{count} shapes to #{compressed_data_path()}", trace?)
    :ok
  end

  @doc """
  Stream the shapes stored in the on-disk TZW1 file.

  Returns `{:ok, version, stream}` where `stream` yields one shape at
  a time. The underlying file handle is closed when the stream is
  fully consumed or halted.
  """
  def stream_shapes do
    path = compressed_data_path()

    case File.open(path, [:read, :binary, :compressed]) do
      {:ok, handle} ->
        case read_header(handle) do
          {:ok, version} ->
            stream =
              Stream.resource(
                fn -> handle end,
                &read_next_shape/1,
                &File.close/1
              )

            {:ok, version, stream}

          {:error, _} = error ->
            File.close(handle)
            error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Read just the data version string from the on-disk TZW1 file
  without iterating its shapes.
  """
  def stored_version do
    path = compressed_data_path()

    case File.open(path, [:read, :binary, :compressed]) do
      {:ok, handle} ->
        try do
          read_header(handle)
        after
          File.close(handle)
        end

      {:error, _} = error ->
        error
    end
  end

  def transform_source_data(source_data, version) when is_list(source_data) do
    transform_source_data(:erlang.list_to_binary(source_data), version)
  end

  def transform_source_data(source_data, version) when is_binary(source_data) do
    case :zip.unzip(source_data, [:memory]) do
      {:ok, [{_, json} | _]} ->
        write_streaming(compressed_data_path(), version, json)

      error ->
        raise RuntimeError, "Unable to unzip downloaded data. Error: #{inspect(error)}"
    end
  end

  defp write_streaming(path, version, json) do
    handle = open_for_write!(path, version)

    try do
      decode_and_stream(json, handle)
    after
      File.close(handle)
    end
  end

  defp open_for_write!(path, version) when is_binary(version) do
    handle = File.open!(path, [:write, :binary, :compressed])
    :ok = IO.binwrite(handle, @magic)
    :ok = IO.binwrite(handle, <<byte_size(version)::16, version::binary>>)
    handle
  end

  defp decode_and_stream(json, handle) do
    # The outer acc threaded through `:json` can't be used to count
    # features: when the parser enters an array, the acc passed to
    # object_finish is the array's accumulator (a list), not our state.
    # Use :counters for a side-channel feature counter and leave the
    # parser's acc untouched.
    counter = :counters.new(1, [])
    decoders = %{object_finish: build_object_finish(handle, counter)}
    {_result, :ok, ""} = :json.decode(json, :ok, decoders)
    :counters.get(counter, 1)
  end

  defp build_object_finish(handle, counter) do
    fn pairs, acc ->
      map = :maps.from_list(pairs)

      case map do
        %{"type" => "Feature", "properties" => properties, "geometry" => geometry} ->
          shape = build_shape(geometry, normalize_properties(properties))
          write_shape!(handle, shape)
          :counters.add(counter, 1, 1)
          {nil, acc}

        other ->
          {other, acc}
      end
    end
  end

  defp write_shape!(handle, shape) do
    bin = :erlang.term_to_binary(shape)
    :ok = IO.binwrite(handle, <<byte_size(bin)::32, bin::binary>>)
  end

  defp read_header(handle) do
    with magic when magic == @magic <- IO.binread(handle, 4),
         <<vsize::16>> <- IO.binread(handle, 2),
         version when is_binary(version) and byte_size(version) == vsize <-
           IO.binread(handle, vsize) do
      {:ok, version}
    else
      :eof -> {:error, :empty_file}
      _other -> {:error, :corrupt_header}
    end
  end

  defp read_next_shape(handle) do
    case IO.binread(handle, 4) do
      :eof ->
        {:halt, handle}

      <<size::32>> ->
        bin = IO.binread(handle, size)

        if is_binary(bin) and byte_size(bin) == size do
          {[:erlang.binary_to_term(bin)], handle}
        else
          raise RuntimeError, "Truncated shape record (expected #{size} bytes)"
        end
    end
  end

  # --- Hand-built Geo struct construction ---

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
