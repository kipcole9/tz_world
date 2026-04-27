# Compares all backends across categorised input regions.
#
# Each input is a *list* of points; the benchmark resolves all points
# in the list per iteration so per-iteration cost reflects the average
# behaviour over the category, not a single (potentially lucky) point.

backends = [
  {"SpatialIndex", TzWorld.Backend.SpatialIndex},
  {"EtsWithIndexCache", TzWorld.Backend.EtsWithIndexCache},
  {"DetsWithIndexCache", TzWorld.Backend.DetsWithIndexCache}
]

for {_name, mod} <- backends, do: mod.start_link()

# Force each backend to finish loading before timing begins.
for {_name, mod} <- backends, do: mod.version()

to_points = fn fixtures ->
  for {lng, lat, _expected, _label} <- fixtures, do: %Geo.Point{coordinates: {lng, lat}}
end

inputs =
  TzWorld.TimezoneFixtures.by_category()
  |> Map.new(fn {category, fixtures} -> {category, to_points.(fixtures)} end)
  |> Map.put("all", to_points.(TzWorld.TimezoneFixtures.all()))
  |> Map.put("random_uniform_50", TzWorld.TimezoneFixtures.random_points(50)
       |> Enum.map(fn {lng, lat} -> %Geo.Point{coordinates: {lng, lat}} end))

scenarios =
  for {name, mod} <- backends, into: %{} do
    {name,
     fn points ->
       Enum.each(points, fn point -> TzWorld.timezone_at(point, mod) end)
     end}
  end

Benchee.run(
  scenarios,
  inputs: inputs,
  time: 3,
  warmup: 1,
  memory_time: 0,
  print: [fast_warning: false]
)
