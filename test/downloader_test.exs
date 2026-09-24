defmodule TzWorld.DownloaderTest do
  # Environment variables and application configuration are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias TzWorld.Downloader

  @unsafe_https "TZWORLD_UNSAFE_HTTPS"

  defp with_env(variable, value, fun) do
    previous = System.get_env(variable)
    if value, do: System.put_env(variable, value), else: System.delete_env(variable)

    try do
      fun.()
    after
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end
  end

  describe "TZWORLD_UNSAFE_HTTPS" do
    test "leaves certificate verification on when unset or set to a false value" do
      for value <- [nil, "", "  ", "false", "FALSE", "False", "nil", "NIL"] do
        assert with_env(@unsafe_https, value, &Downloader.secure_ssl?/0),
               "value: #{inspect(value)}"
      end
    end

    test "turns certificate verification off when set to any other value" do
      for value <- ["true", "TRUE", "1", "yes"] do
        refute with_env(@unsafe_https, value, &Downloader.secure_ssl?/0),
               "value: #{inspect(value)}"
      end
    end
  end

  describe "certificate trust store" do
    test "the configured :cacertfile is tried first" do
      previous = Application.get_env(:tz_world, :cacertfile)
      Application.put_env(:tz_world, :cacertfile, "/path/to/cacertfile.pem")

      try do
        assert hd(Downloader.certificate_locations()) == "/path/to/cacertfile.pem"
      after
        if previous,
          do: Application.put_env(:tz_world, :cacertfile, previous),
          else: Application.delete_env(:tz_world, :cacertfile)
      end
    end
  end

  describe "timeouts" do
    # Nothing listens on port 1, so the request fails at once without
    # needing the network, after the timeouts have been read.
    test "an invalid TZWORLD_HTTP_TIMEOUT falls back to the default instead of raising" do
      log =
        with_env("TZWORLD_HTTP_TIMEOUT", "two minutes", fn ->
          capture_log(fn ->
            assert {:error, _reason} = Downloader.get("https://127.0.0.1:1/")
          end)
        end)

      assert log =~ "TZWORLD_HTTP_TIMEOUT is not a number of milliseconds"
    end
  end
end
