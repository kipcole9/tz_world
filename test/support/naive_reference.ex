defmodule TzWorld.NaiveReference do
  @moduledoc false

  # A deliberately simple, independent implementation of point-in-timezone
  # lookup, used as the oracle against which `TzWorld.Backend.SpatialIndex`
  # is validated.
  #
  # It reads the same `.tzw1` data file the backend reads, then answers a
  # query by scanning every shape's bounding box and ray casting into the
  # shapes whose box matches. That is the algorithm the deprecated ETS and
  # DETS backends used, reimplemented here so the differential test depends
  # on no backend and needs no `.dets` cache. Reading the same source of
  # truth as the backend also keeps the comparison about the algorithm
  # rather than about which data release each side happens to hold.
  #
  # The shapes live in an ETS table and only their bounding boxes go in
  # `:persistent_term`. The shapes deliberately do not: `SpatialIndex`
  # already holds a full copy of them there, and a second copy exhausts
  # the literal allocator. The boxes are a few megabytes of floats, and
  # keeping them in `:persistent_term` means each of the thousands of
  # lookups reads them without copying.

  alias TzWorld.GeoData

  @table __MODULE__
  @boxes_key {__MODULE__, :bounding_boxes}

  @doc "Loads the shape data. Call once, from `setup_all`."
  def load do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    else
      :ets.delete_all_objects(@table)
    end

    {:ok, _version, shapes} = GeoData.stream_shapes()

    boxes =
      shapes
      |> Enum.with_index()
      |> Enum.flat_map(fn {shape, index} ->
        true = :ets.insert(@table, {index, shape})
        shape |> bounding_boxes() |> Enum.map(&{bounds(&1), index})
      end)

    :persistent_term.put(@boxes_key, boxes)
    :ok
  end

  @doc "Returns the first timezone whose shape contains `point`."
  def timezone_at(%Geo.Point{} = point) do
    point
    |> candidates()
    |> Enum.find(&TzWorld.contains?(&1, point))
    |> case do
      nil -> {:error, :time_zone_not_found}
      shape -> {:ok, shape.properties.tzid}
    end
  end

  @doc "Returns every timezone whose shape contains `point`."
  def all_timezones_at(%Geo.Point{} = point) do
    zones =
      point
      |> candidates()
      |> Enum.filter(&TzWorld.contains?(&1, point))
      |> Enum.map(& &1.properties.tzid)

    {:ok, zones}
  end

  defp candidates(%Geo.Point{coordinates: {lng, lat}}) do
    @boxes_key
    |> :persistent_term.get()
    |> Enum.filter(fn {{xmin, xmax, ymin, ymax}, _index} ->
      lng >= xmin and lng <= xmax and lat >= ymin and lat <= ymax
    end)
    |> Enum.map(fn {_bounds, index} ->
      [{^index, shape}] = :ets.lookup(@table, index)
      shape
    end)
  end

  defp bounding_boxes(%{properties: %{bounding_box: %Geo.Polygon{} = bbox}}), do: [bbox]

  defp bounding_boxes(%{properties: %{bounding_box: bboxes}}) when is_list(bboxes), do: bboxes

  defp bounds(%Geo.Polygon{coordinates: [ring | _]}) do
    Enum.reduce(ring, {180.0, -180.0, 90.0, -90.0}, fn {x, y}, {xmin, xmax, ymin, ymax} ->
      {min(x, xmin), max(x, xmax), min(y, ymin), max(y, ymax)}
    end)
  end
end
