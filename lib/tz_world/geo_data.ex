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
  @chunk_size 64 * 1024

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
  Transform a downloaded GeoJSON source zip (already on disk at
  `source_zip_path`) into the on-disk TZW1 file.

  The source zip is unzipped to a tempdir, the resulting JSON is
  parsed in fixed-size chunks via `:json.decode_start/3` +
  `:json.decode_continue/2`, and each parsed Feature is converted to
  a `Geo.Polygon` / `Geo.MultiPolygon` struct (with bounding box) and
  written to disk immediately. The tempdir is removed on exit.

  Memory stays bounded by one feature's coordinates plus the parser's
  per-chunk buffer (default 64 KiB). The full source zip and the full
  unzipped GeoJSON are never resident in memory.
  """
  def generate_compressed_data(source_zip_path, version, trace? \\ false, force? \\ false)
      when is_binary(source_zip_path) and is_binary(version) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "tz_world_extract_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    try do
      maybe_log("Extracting #{source_zip_path} to #{tmp_dir}", trace?)
      json_path = unzip_to_dir!(source_zip_path, tmp_dir)

      maybe_log("Streaming JSON from #{json_path}", trace?)
      count = transform_json_file(json_path, version, force?)
      maybe_log("Wrote #{count} shapes to #{compressed_data_path()}", trace?)
      :ok
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp unzip_to_dir!(zip_path, dir) do
    case :zip.unzip(String.to_charlist(zip_path), [{:cwd, String.to_charlist(dir)}]) do
      {:ok, [path | _]} ->
        List.to_string(path)

      error ->
        raise RuntimeError, "Unable to unzip #{zip_path}. Error: #{inspect(error)}"
    end
  end

  defp transform_json_file(json_path, version, force?) do
    json_handle = File.open!(json_path, [:read, :binary, :raw, {:read_ahead, @chunk_size}])
    final_path = compressed_data_path() |> List.to_string()
    temp_path = "#{final_path}.tmp.#{:erlang.unique_integer([:positive])}"

    try do
      count = write_to_temp_then_rename!(json_handle, temp_path, final_path, version, force?)
      count
    after
      File.close(json_handle)
    end
  end

  # Stream the parsed shapes into `temp_path`, then atomically rename
  # over `final_path`. This means readers (in this BEAM or another)
  # never observe a partially-written file: they either keep their
  # handle to the previous inode or open the new one in full. On any
  # failure the temp file is cleaned up and `final_path` is left
  # untouched.
  defp write_to_temp_then_rename!(json_handle, temp_path, final_path, version, force?) do
    out_handle = open_for_write!(temp_path, version, force?)

    count =
      try do
        decode_and_stream_chunked(json_handle, out_handle)
      after
        File.close(out_handle)
      end

    File.rename!(temp_path, final_path)
    count
  rescue
    error ->
      _ = File.rm(temp_path)
      reraise error, __STACKTRACE__
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

  defp open_for_write!(path, version, force?) when is_binary(version) and is_boolean(force?) do
    # When `force?` is true, create any missing parent directories
    # under the configured `:data_dir`. Without `force?` the writer
    # surfaces the underlying File.Error so a misconfigured
    # :data_dir is loud rather than silently materialised.
    if force?, do: File.mkdir_p!(Path.dirname(path))
    handle = File.open!(path, [:write, :binary, :compressed])
    :ok = IO.binwrite(handle, @magic)
    :ok = IO.binwrite(handle, <<byte_size(version)::16, version::binary>>)
    handle
  end

  defp decode_and_stream_chunked(json_handle, out_handle) do
    # The outer acc threaded through `:json` can't be used to count
    # features: when the parser enters an array, the acc passed to
    # object_finish is the array's accumulator (a list), not our state.
    # Use :counters for a side-channel feature counter and leave the
    # parser's acc untouched.
    counter = :counters.new(1, [])
    decoders = %{object_finish: build_object_finish(out_handle, counter)}

    case IO.binread(json_handle, @chunk_size) do
      :eof ->
        raise RuntimeError, "Empty JSON input"

      first_chunk when is_binary(first_chunk) ->
        drive(json_handle, :json.decode_start(first_chunk, :ok, decoders))
    end

    :counters.get(counter, 1)
  end

  # Parser already produced a final value — no more input needed.
  defp drive(_json_handle, {_result, _acc, _rest}), do: :ok

  # Parser wants more input. Feed the next chunk, or signal EOF.
  defp drive(json_handle, {:continue, state}) do
    case IO.binread(json_handle, @chunk_size) do
      :eof ->
        _ = :json.decode_continue(:end_of_input, state)
        :ok

      chunk when is_binary(chunk) ->
        drive(json_handle, :json.decode_continue(chunk, state))
    end
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
