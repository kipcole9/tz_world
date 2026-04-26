defmodule TzWorld.SpatialIndex do
  @moduledoc false

  # Pure-Elixir R-tree for stabbing queries over axis-aligned 2D rectangles.
  #
  # Built once via Sort-Tile-Recursive bulk loading and stored as a single
  # nested-tuple term so it lives happily in `:persistent_term`.
  #
  # Node shape (uniform for leaves and internal nodes):
  #
  #     {xmin, xmax, ymin, ymax, child}
  #
  # where `child` is an integer leaf id when the node is a leaf, or a
  # tuple of child nodes when it is internal. The two cases are
  # distinguished with `is_integer/1`.

  @node_capacity 16

  @type rect :: {number, number, number, number}
  @type entry :: {number, number, number, number, non_neg_integer}
  @type tree :: entry | {number, number, number, number, tuple}

  @doc """
  Build an R-tree from a list of `{xmin, xmax, ymin, ymax, leaf_id}` entries.

  Multiple entries may share the same `leaf_id` (e.g. one entry per
  sub-polygon of a MultiPolygon, all referring to the same shape index).
  Returns `nil` for an empty input.
  """
  @spec build([entry]) :: tree | nil
  def build([]), do: nil
  def build([single]), do: single

  def build(entries) when is_list(entries) do
    str_pack(entries)
  end

  defp str_pack(entries) when length(entries) <= @node_capacity do
    pack_node(entries)
  end

  defp str_pack(entries) do
    n = length(entries)
    leaves_target = ceil(n / @node_capacity)
    slices = max(1, ceil(:math.sqrt(leaves_target)))
    slice_size = max(@node_capacity, ceil(n / slices))

    nodes =
      entries
      |> Enum.sort_by(fn {xmin, xmax, _, _, _} -> xmin + xmax end)
      |> Enum.chunk_every(slice_size)
      |> Enum.flat_map(fn slice ->
        slice
        |> Enum.sort_by(fn {_, _, ymin, ymax, _} -> ymin + ymax end)
        |> Enum.chunk_every(@node_capacity)
        |> Enum.map(&pack_node/1)
      end)

    str_pack(nodes)
  end

  defp pack_node([single]), do: single

  defp pack_node(children) do
    {xmin, xmax, ymin, ymax} = mbr(children)
    {xmin, xmax, ymin, ymax, List.to_tuple(children)}
  end

  defp mbr([{xmin, xmax, ymin, ymax, _} | rest]) do
    Enum.reduce(rest, {xmin, xmax, ymin, ymax}, fn
      {a, b, c, d, _}, {xmin, xmax, ymin, ymax} ->
        {min(a, xmin), max(b, xmax), min(c, ymin), max(d, ymax)}
    end)
  end

  @doc """
  Return the leaf ids of every entry whose rectangle contains the point
  `(lng, lat)`. Order is unspecified; duplicates are possible when
  multiple entries share a leaf id (callers should dedupe if needed).
  """
  @spec stab(tree | nil, number, number) :: [non_neg_integer]
  def stab(nil, _lng, _lat), do: []

  def stab(tree, lng, lat) do
    stab_node(tree, lng, lat, [])
  end

  defp stab_node({xmin, xmax, ymin, ymax, child}, lng, lat, acc)
       when lng >= xmin and lng <= xmax and lat >= ymin and lat <= ymax do
    if is_integer(child) do
      [child | acc]
    else
      stab_children(child, tuple_size(child), lng, lat, acc)
    end
  end

  defp stab_node(_node, _lng, _lat, acc), do: acc

  defp stab_children(_children, 0, _lng, _lat, acc), do: acc

  defp stab_children(children, n, lng, lat, acc) do
    stab_children(children, n - 1, lng, lat, stab_node(:erlang.element(n, children), lng, lat, acc))
  end
end
