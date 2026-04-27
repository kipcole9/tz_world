defmodule TzWorld.TimezoneFixtures do
  @moduledoc """
  Coordinate fixtures used by the test suite and the benchmark.

  Grouped into categories that exercise different parts of the spatial
  index: dense regions where many bounding boxes overlap; sparse / very
  large zones; small or thin zones; ocean points (no match); and points
  close to a polygon boundary.

  Each entry is `{lng, lat, expected_tzid_or_nil, label}`.
  """

  @densely_indexed [
    {2.3522, 48.8566, "Europe/Paris", "Paris"},
    {-0.1276, 51.5074, "Europe/London", "London"},
    {13.4050, 52.5200, "Europe/Berlin", "Berlin"},
    {-3.7038, 40.4168, "Europe/Madrid", "Madrid"},
    {12.4964, 41.9028, "Europe/Rome", "Rome"},
    {4.9041, 52.3676, "Europe/Amsterdam", "Amsterdam"},
    {-74.0060, 40.7128, "America/New_York", "New York"},
    {-87.6298, 41.8781, "America/Chicago", "Chicago"},
    {-118.2437, 34.0522, "America/Los_Angeles", "Los Angeles"},
    {-79.3832, 43.6532, "America/Toronto", "Toronto"},
    {139.6917, 35.6895, "Asia/Tokyo", "Tokyo"},
    {116.4074, 39.9042, "Asia/Shanghai", "Beijing"},
    {103.8198, 1.3521, "Asia/Singapore", "Singapore"},
    {72.8777, 19.0760, "Asia/Kolkata", "Mumbai"},
    {151.2093, -33.8688, "Australia/Sydney", "Sydney"}
  ]

  @sparse_or_large [
    # Mid-Pacific, far from any landmass — falls in a maritime/Etc zone.
    {-150.0, 0.0, nil, "mid-Pacific equator"},
    # Antarctic interior.
    {0.0, -85.0, "Antarctica/Troll", "Antarctic interior"},
    # Saharan interior (this point is in Chad).
    {15.0, 23.0, "Africa/Ndjamena", "Saharan Chad"},
    # Siberian interior.
    {110.0, 65.0, "Asia/Yakutsk", "Siberian interior"},
    # Eastern Russia close to IDL.
    {170.0, 67.0, "Asia/Anadyr", "Chukotka"},
    # Greenland interior.
    {-40.0, 72.0, "America/Nuuk", "Greenland interior"}
  ]

  @small_or_thin [
    # Indiana has a famously fragmented set of timezones.
    {-86.1581, 39.7684, "America/Indiana/Indianapolis", "Indianapolis"},
    {-86.6253, 41.2961, "America/Indiana/Knox", "Knox IN"},
    {-85.7585, 38.2527, "America/Kentucky/Louisville", "Louisville"},
    # Small countries.
    {35.2137, 31.7683, "Asia/Jerusalem", "Jerusalem"},
    {36.8219, -1.2921, "Africa/Nairobi", "Nairobi"},
    {-66.9036, 10.4806, "America/Caracas", "Caracas"},
    {-58.3816, -34.6037, "America/Argentina/Buenos_Aires", "Buenos Aires"},
    # Russia: Asia/Barnaul is a known-edge case in older libraries.
    {85.95926, 51.95874, "Asia/Barnaul", "Barnaul"},
    # Kathmandu (UTC+5:45 — odd offset zone).
    {85.3240, 27.7172, "Asia/Kathmandu", "Kathmandu"}
  ]

  @ocean [
    {-30.0, 30.0, nil, "mid-Atlantic"},
    {-140.0, 30.0, nil, "mid-east-Pacific"},
    {80.0, -30.0, nil, "south Indian"},
    {-100.0, -50.0, nil, "south Pacific"},
    {1.3, 65.62, nil, "North Sea (existing test)"}
  ]

  @international_date_line [
    {179.9, -16.5, "Pacific/Fiji", "Fiji just west of IDL"},
    {-170.7012, -14.2756, "Pacific/Pago_Pago", "American Samoa just east of IDL"},
    {-176.5, 51.9, "America/Adak", "Aleutians"}
  ]

  @doc "All fixtures with known-good `tzid` (or `nil` for ocean/no-match)."
  def all do
    @densely_indexed ++ @sparse_or_large ++ @small_or_thin ++ @ocean ++ @international_date_line
  end

  @doc "Fixtures grouped by category, suitable for Benchee `:inputs`."
  def by_category do
    %{
      "dense" => @densely_indexed,
      "sparse_or_large" => @sparse_or_large,
      "small_or_thin" => @small_or_thin,
      "ocean" => @ocean,
      "idl" => @international_date_line
    }
  end

  @doc """
  Generate `count` uniformly random `(lng, lat)` points. Used by the
  property test to compare backends on traffic the curated fixtures
  cannot anticipate. Pass `seed` for reproducibility.
  """
  def random_points(count, seed \\ {1, 2, 3}) do
    :rand.seed(:exsplus, seed)

    for _ <- 1..count do
      lng = :rand.uniform() * 360.0 - 180.0
      lat = :rand.uniform() * 180.0 - 90.0
      {lng, lat}
    end
  end
end
