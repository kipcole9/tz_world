defmodule TzWorld.Downloader do
  @moduledoc """
  Downloads the time zone boundary data from the
  [timezone-boundary-builder](https://github.com/evansiroky/timezone-boundary-builder)
  releases on GitHub.

  `mix tz_world.update` is the usual way to install the data, and
  `update_release/1` does the same from code.

  ### Configuration

  Downloads are made with `:httpc` over HTTPS, verifying the server's
  certificate. They can be configured with:

  * `config :tz_world, cacertfile: path` to name the certificate trust
    store. Without it, the store from the `castore` or `certifi` package
    is used if either is installed, and otherwise the first of several
    well-known system locations that exists.

  * `config :tz_world, https_proxy: url`, or the `HTTPS_PROXY` or
    `https_proxy` environment variable, to download through a proxy.

  * the `TZWORLD_HTTP_TIMEOUT` and `TZWORLD_HTTP_CONNECTION_TIMEOUT`
    environment variables, in milliseconds, to change the request timeout
    from 120,000 and the connection timeout from 60,000.

  * the `TZWORLD_UNSAFE_HTTPS` environment variable, which turns off
    certificate verification when it is set to anything other than an
    empty string, `false` or `nil`. This is not recommended.

  """

  alias TzWorld.GeoData

  import TzWorld, only: [maybe_log: 2]

  @release_url "https://api.github.com/repos/evansiroky/timezone-boundary-builder/releases"
  @timezones_geojson "timezones.geojson.zip"
  @timezones_with_oceans_geojson "timezones-with-oceans.geojson.zip"

  @tzworld_unsafe_https "TZWORLD_UNSAFE_HTTPS"
  @tzworld_default_timeout "120000"
  @tzworld_default_connection_timeout "60000"

  @doc """
  Returns the latest release of the time zone boundary data.

  ### Arguments

  * `include_oceans?` is a boolean. When `true` the download URL is for
    the data that also covers the oceans. The default is `false`.

  * `trace?` is a boolean. When `true` progress is logged at the debug
    level. The default is `false`.

  ### Returns

  * `{release, url}` where `release` is the name of the release and `url`
    is the download URL of its data.

  A `RuntimeError` is raised if the list of releases cannot be fetched.

  ### Examples

      iex> TzWorld.Downloader.latest_release()
      {"2026d", "https://github.com/evansiroky/timezone-boundary-builder/releases/download/2026d/timezones.geojson.zip"}

  """
  def latest_release(include_oceans? \\ false, trace? \\ false) do
    case get_releases(trace?) do
      {:ok, releases} ->
        release = hd(releases)
        release_number = Map.get(release, "name")
        asset_name = asset_name(include_oceans?)
        timezones_geojson_asset = find_asset(release, asset_name)
        asset_url = Map.get(timezones_geojson_asset, "browser_download_url")
        {release_number, asset_url}

      {:error, reason} ->
        raise RuntimeError,
              "Failed to fetch the latest release information from " <>
                "#{@release_url}: #{inspect(reason)}"
    end
  end

  defp asset_name(true), do: @timezones_with_oceans_geojson
  defp asset_name(false), do: @timezones_geojson

  @doc """
  Returns the release of the installed time zone boundary data.

  The release is read from the installed data file, so no backend needs
  to be running.

  ### Returns

  * `{:ok, release}` where `release` is the name of the release.

  * `{:error, reason}` if no data is installed, when `reason` is
    `:enoent`, or the installed file cannot be read.

  ### Examples

      iex> TzWorld.Downloader.current_release()
      {:ok, "2026d"}

  """
  def current_release do
    GeoData.stored_version()
  end

  @doc """
  Installs the latest time zone boundary data if it is newer than the
  installed data.

  The data is downloaded, compressed into the data directory and then
  loaded into every running backend with `TzWorld.reload_timezone_data/0`.

  ### Arguments

  * `options` is a keyword list of options.

  ### Options

  * `:include_oceans` is a boolean. When `true` the data that also covers
    the oceans is installed. The default is `false`.

  * `:force` is a boolean. When `true` the latest data is installed even
    if it is already installed, which is how to switch between the data
    with and without the oceans. The default is `false`.

  * `:trace` is a boolean. When `true` progress is logged at the debug
    level. The default is `false`.

  ### Returns

  * `{:ok, release}` if the installed data is already the latest release.

  * The result of `TzWorld.reload_timezone_data/0` once the latest data
    has been installed.

  * `{:error, reason}` if the download fails.

  A `RuntimeError` is raised if the list of releases cannot be fetched.

  ### Examples

      iex> TzWorld.Downloader.update_release()
      {:ok, "2026d"}

  """
  def update_release(options \\ []) do
    include_oceans? = Keyword.get(options, :include_oceans, false)
    force_update? = Keyword.get(options, :force, false)
    trace? = Keyword.get(options, :trace, false)

    update_release(include_oceans?, force_update?, trace?)
  end

  @doc false
  def update_release(include_oceans?, true = _force_update?, trace?) do
    {latest_release, asset_url} = latest_release(include_oceans?)
    get_and_load_latest_release(latest_release, asset_url, trace?, true)
  end

  def update_release(include_oceans?, false = _force_update?, trace?) do
    case current_release() do
      {:ok, current_release} ->
        {latest_release, asset_url} = latest_release(include_oceans?)

        if latest_release > current_release do
          get_and_load_latest_release(latest_release, asset_url, trace?)
        else
          {:ok, current_release}
        end

      # Not installed, or the installed file cannot be read: install afresh.
      {:error, _reason} ->
        {latest_release, asset_url} = latest_release(include_oceans?, trace?)
        get_and_load_latest_release(latest_release, asset_url, trace?)
    end
  end

  # Retained for backwards compatibility; behaviour is now identical
  # to `get_latest_release/4` since the latter triggers a full
  # `TzWorld.reload_timezone_data/0` after writing the new on-disk
  # file.
  @doc false
  def get_and_load_latest_release(latest_release, asset_url, trace?, force? \\ false) do
    get_latest_release(latest_release, asset_url, trace?, force?)
  end

  @doc false
  def get_latest_release(latest_release, asset_url, trace? \\ false, force? \\ false) do
    tmp_zip =
      Path.join(
        System.tmp_dir!(),
        "tz_world_source_#{:erlang.unique_integer([:positive])}.zip"
      )

    try do
      with {:ok, _} <- stream_get_url(asset_url, tmp_zip, trace?) do
        GeoData.generate_compressed_data(tmp_zip, latest_release, trace?, force?)
        # Reload every running backend from the new on-disk file. This
        # rebuilds the DETS file (DetsWithIndexCache reload), refreshes
        # the ETS cache (EtsWithIndexCache reload), and atomically swaps
        # the SpatialIndex persistent_term entry. Backends that are not
        # running in this node are skipped.
        TzWorld.reload_timezone_data()
      end
    after
      File.rm(tmp_zip)
    end
  end

  defp find_asset(release, requested_asset) do
    Map.get(release, "assets")
    |> Enum.find(fn asset -> Map.get(asset, "name") == requested_asset end)
  end

  defp get_releases(trace?) do
    with {:ok, json} <- get_url(@release_url),
         {:ok, releases} <- json_decode(json) do
      maybe_log(
        "Retrieved list of #{Enum.count(releases)} available timezone data releases.",
        trace?
      )

      {:ok, releases}
    end
  end

  defp json_decode(json) do
    case :json.decode(json, :ok, %{null: nil}) do
      {term, :ok, rest} ->
        # Some servers include a trailing newline after the JSON body.
        # Jason silently tolerated this; `:json` returns the leftover
        # in `rest`. Allow whitespace-only trailers.
        case String.trim(rest) do
          "" -> {:ok, term}
          leftover -> {:error, {:trailing_data, byte_size(leftover)}}
        end
    end
  rescue
    e -> {:error, {:invalid_json, Exception.message(e)}}
  end

  @doc false
  def get_url(url) do
    headers = [{String.to_charlist("User-Agent"), user_agent()}]
    get({url, headers})
  end

  @doc """
  Downloads a URL to a file without holding the response in memory.

  ### Arguments

  * `url` is the URL to download.

  * `path` is the path of the file the response body is written to.

  * `trace?` is a boolean. When `true` the download is logged at the
    debug level. The default is `false`.

  ### Returns

  * `{:ok, path}` once the response body has been written to `path`.

  * `{:error, reason}` if the download fails, where `reason` is the HTTP
    status code or the `:httpc` error. The failure is also logged.

  ### Examples

      iex> path = Path.join(System.tmp_dir!(), "example.html")
      iex> {:ok, ^path} = TzWorld.Downloader.stream_get_url("https://example.com", path)
      iex> File.exists?(path)
      true

  """
  def stream_get_url(url, path, trace? \\ false) when is_binary(url) and is_binary(path) do
    headers = [{String.to_charlist("User-Agent"), user_agent()}]
    maybe_log("Streaming download from #{url} to #{path}", trace?)
    stream_get({url, headers}, path, [])
  end

  defp stream_get({url, headers}, path, options) do
    hostname = String.to_charlist(URI.parse(url).host)
    url_charlist = String.to_charlist(url)
    http_options = http_opts(hostname, options)
    https_proxy = https_proxy(options)

    if https_proxy do
      case URI.parse(https_proxy) do
        %{host: host, port: port} when is_binary(host) and is_integer(port) ->
          :httpc.set_options([{:https_proxy, {{String.to_charlist(host), port}, []}}])

        _other ->
          Logger.bare_log(
            :warning,
            "https_proxy was set to an invalid value. Found #{inspect(https_proxy)}."
          )
      end
    end

    request_options = [stream: String.to_charlist(path)]

    case :httpc.request(:get, {url_charlist, headers}, http_options, request_options) do
      {:ok, :saved_to_file} ->
        {:ok, path}

      {:ok, {{_version, code, message}, _headers, _body}} ->
        Logger.bare_log(
          :error,
          "Failed to download #{inspect(url)}. " <>
            "HTTP Error: (#{code}) #{inspect(message)}"
        )

        {:error, code}

      {:error, _} = error ->
        Logger.bare_log(:error, "Failed to download #{inspect(url)}: #{inspect(error)}")
        error
    end
  end

  @doc """
  Downloads the body of an HTTPS URL.

  The request is made with `:httpc`, verifying the server's certificate as
  the [EEF security guidelines](https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/ssl)
  recommend. The trust store, proxy and timeouts are configured as the
  module documentation describes.

  ### Arguments

  * `url` is the URL as a string, or a `{url, headers}` tuple where
    `headers` is a list of `{name, value}` tuples of charlists.

  * `options` is a keyword list of options.

  ### Options

  * `:verify_peer` is a boolean. When `false` the server's certificate is
    not verified. The default is `true`.

  * `:timeout` is the number of milliseconds the request may take. The
    default is the value of `TZWORLD_HTTP_TIMEOUT`, or 120,000.

  * `:connection_timeout` is the number of milliseconds allowed to
    connect to the server. The default is the value of
    `TZWORLD_HTTP_CONNECTION_TIMEOUT`, or 60,000.

  * `:https_proxy` is the URL of a proxy to download through. The default
    is the configured `:https_proxy`, or the `HTTPS_PROXY` or
    `https_proxy` environment variable.

  ### Returns

  * `{:ok, body}` if the server responds with status 200.

  * `{:not_modified, headers}` if the server responds with status 304,
    which needs a conditional request header such as `If-None-Match`.

  * `{:error, reason}` otherwise, where `reason` is the HTTP status code
    or the `:httpc` error. The failure is also logged.

  ### Examples

      iex> {:ok, body} = TzWorld.Downloader.get("https://example.com")
      iex> String.starts_with?(body, "<!doctype html>")
      true

  """
  @spec get(String.t() | {String.t(), list()}, options :: Keyword.t()) ::
          {:ok, binary} | {:not_modified, any()} | {:error, any}

  def get(url, options \\ [])

  def get(url, options) when is_binary(url) and is_list(options) do
    case get_with_headers(url, options) do
      {:ok, _headers, body} -> {:ok, body}
      other -> other
    end
  end

  def get({url, headers}, options)
      when is_binary(url) and is_list(headers) and is_list(options) do
    case get_with_headers({url, headers}, options) do
      {:ok, _headers, body} -> {:ok, body}
      other -> other
    end
  end

  @doc """
  Downloads the headers and body of an HTTPS URL.

  The request is made as `get/2` describes.

  ### Arguments

  * `url` is the URL as a string, or a `{url, headers}` tuple where
    `headers` is a list of `{name, value}` tuples of charlists.

  * `options` is a keyword list of options.

  ### Options

  * The options are those of `get/2`.

  ### Returns

  * `{:ok, headers, body}` if the server responds with status 200, where
    `headers` is a list of `{name, value}` tuples of charlists.

  * `{:not_modified, headers}` if the server responds with status 304.

  * `{:error, reason}` otherwise, where `reason` is the HTTP status code
    or the `:httpc` error. The failure is also logged.

  ### Examples

      iex> {:ok, headers, _body} = TzWorld.Downloader.get_with_headers("https://example.com")
      iex> List.keymember?(headers, ~c"content-type", 0)
      true

  """
  @spec get_with_headers(String.t() | {String.t(), list()}, options :: Keyword.t()) ::
          {:ok, list(), binary} | {:not_modified, any()} | {:error, any}

  def get_with_headers(request, options \\ [])

  def get_with_headers(url, options) when is_binary(url) do
    get_with_headers({url, []}, options)
  end

  def get_with_headers({url, headers}, options)
      when is_binary(url) and is_list(headers) and is_list(options) do
    hostname = String.to_charlist(URI.parse(url).host)
    url = String.to_charlist(url)
    http_options = http_opts(hostname, options)
    https_proxy = https_proxy(options)

    if https_proxy do
      case URI.parse(https_proxy) do
        %{host: host, port: port} when is_binary(host) and is_integer(port) ->
          :httpc.set_options([{:https_proxy, {{String.to_charlist(host), port}, []}}])

        _other ->
          Logger.bare_log(
            :warning,
            "https_proxy was set to an invalid value. Found #{inspect(https_proxy)}."
          )
      end
    end

    # body_format: :binary so callers (incl. :json.decode/3) get a binary,
    # not a charlist. The default `:string` returns a list of integers,
    # which Jason tolerated but :json does not.
    case :httpc.request(:get, {url, headers}, http_options, body_format: :binary) do
      {:ok, {{_version, 200, _}, headers, body}} ->
        {:ok, headers, body}

      {:ok, {{_version, 304, _}, headers, _body}} ->
        {:not_modified, headers}

      {_, {{_version, code, message}, _headers, _body}} ->
        Logger.bare_log(
          :error,
          "Failed to download #{inspect(url)}. " <>
            "HTTP Error: (#{code}) #{inspect(message)}"
        )

        {:error, code}

      {:error, {:failed_connect, [{_, {host, _port}}, {_, _, sys_message}]}} ->
        if sys_message == :timeout do
          Logger.bare_log(
            :error,
            "Timeout connecting to #{inspect(host)} to download #{inspect(url)}. " <>
              "Connection time exceeded #{http_options[:connect_timeout]}ms."
          )

          {:error, :connection_timeout}
        else
          Logger.bare_log(
            :error,
            "Failed to connect to #{inspect(host)} to download #{inspect(url)}"
          )

          {:error, sys_message}
        end

      {:error, {other}} ->
        Logger.bare_log(
          :error,
          "Failed to download #{inspect(url)}. Error #{inspect(other)}"
        )

        {:error, other}

      {:error, :timeout} ->
        Logger.bare_log(
          :error,
          "Timeout downloading from #{inspect(url)}. " <>
            "Request exceeded #{http_options[:timeout]}ms."
        )

        {:error, :timeout}

      {:error, reason} ->
        Logger.bare_log(
          :error,
          "Failed to download #{inspect(url)}. Error #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @static_certificate_locations [
    # Debian/Ubuntu/Gentoo etc.
    "/etc/ssl/certs/ca-certificates.crt",

    # Fedora/RHEL 6
    "/etc/pki/tls/certs/ca-bundle.crt",

    # OpenSUSE
    "/etc/ssl/ca-bundle.pem",

    # OpenELEC
    "/etc/pki/tls/cacert.pem",

    # CentOS/RHEL 7
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",

    # Open SSL on MacOS
    "/usr/local/etc/openssl/cert.pem",

    # MacOS & Alpine Linux
    "/etc/ssl/cert.pem"
  ]

  defp dynamic_certificate_locations do
    [
      # Configured cacertfile
      Application.get_env(:tz_world, :cacertfile),

      # Populated if hex package CAStore is configured
      if(Code.ensure_loaded?(CAStore), do: apply(CAStore, :file_path, [])),

      # Populated if hex package certifi is configured
      if(Code.ensure_loaded?(:certifi), do: apply(:certifi, :cacertfile, []) |> List.to_string())
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  def certificate_locations() do
    dynamic_certificate_locations() ++ @static_certificate_locations
  end

  defp certificate_store do
    certificate_locations()
    |> Enum.find(&File.exists?/1)
    |> raise_if_no_cacertfile!
    |> :erlang.binary_to_list()
  end

  defp raise_if_no_cacertfile!(nil) do
    raise RuntimeError, """
    No certificate trust store was found.
    Tried looking for: #{inspect(certificate_locations())}

    A certificate trust store is required in
    order to download the time zone data.

    Since tz_world could not detect a system
    installed certificate trust store one of the
    following actions may be taken:

    1. Install the hex package `castore`. It will
       be automatically detected after recompilation.

    2. Install the hex package `certifi`. It will
       be automatically detected after recompilation.

    3. Specify the location of a certificate trust store
       by configuring it in `config.exs` or `runtime.exs`:

       config :tz_world,
         cacertfile: "/path/to/cacertfile"

    """
  end

  defp raise_if_no_cacertfile!(file) do
    file
  end

  defp http_opts(hostname, options) do
    default_timeout = env_milliseconds("TZWORLD_HTTP_TIMEOUT", @tzworld_default_timeout)

    default_connection_timeout =
      env_milliseconds("TZWORLD_HTTP_CONNECTION_TIMEOUT", @tzworld_default_connection_timeout)

    verify_peer? = Keyword.get(options, :verify_peer, true)
    ssl_options = https_ssl_opts(hostname, verify_peer?)
    timeout = Keyword.get(options, :timeout, default_timeout)
    connection_timeout = Keyword.get(options, :connection_timeout, default_connection_timeout)

    [timeout: timeout, connect_timeout: connection_timeout, ssl: ssl_options]
  end

  # A variable that is set but is not a positive whole number of
  # milliseconds falls back to the default rather than failing the download.
  defp env_milliseconds(variable, default) do
    case Integer.parse(System.get_env(variable, default)) do
      {milliseconds, ""} when milliseconds > 0 ->
        milliseconds

      _other ->
        Logger.bare_log(
          :warning,
          "#{variable} is not a number of milliseconds. Using #{default} instead."
        )

        String.to_integer(default)
    end
  end

  defp user_agent do
    "erlang httpc/tz_world OTP version #{otp_version()}"
    |> String.to_charlist()
  end

  defp https_ssl_opts(hostname, verify_peer?) do
    if secure_ssl?() and verify_peer? do
      [
        verify: :verify_peer,
        cacertfile: certificate_store(),
        depth: 4,
        ciphers: preferred_ciphers(),
        versions: protocol_versions(),
        eccs: preferred_eccs(),
        reuse_sessions: true,
        server_name_indication: hostname,
        secure_renegotiate: true,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    else
      [
        verify: :verify_none,
        server_name_indication: hostname,
        secure_renegotiate: true,
        reuse_sessions: true,
        versions: protocol_versions(),
        ciphers: preferred_ciphers(),
        versions: protocol_versions()
      ]
    end
  end

  defp preferred_ciphers do
    preferred_ciphers =
      [
        # Cipher suites (TLS 1.3): TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
        %{cipher: :aes_128_gcm, key_exchange: :any, mac: :aead, prf: :sha256},
        %{cipher: :aes_256_gcm, key_exchange: :any, mac: :aead, prf: :sha384},
        %{cipher: :chacha20_poly1305, key_exchange: :any, mac: :aead, prf: :sha256},

        # Cipher suites (TLS 1.2): ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:
        # ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:
        # ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
        %{cipher: :aes_128_gcm, key_exchange: :ecdhe_ecdsa, mac: :aead, prf: :sha256},
        %{cipher: :aes_128_gcm, key_exchange: :ecdhe_rsa, mac: :aead, prf: :sha256},
        %{cipher: :aes_256_gcm, key_exchange: :ecdh_ecdsa, mac: :aead, prf: :sha384},
        %{cipher: :aes_256_gcm, key_exchange: :ecdh_rsa, mac: :aead, prf: :sha384},
        %{cipher: :chacha20_poly1305, key_exchange: :ecdhe_ecdsa, mac: :aead, prf: :sha256},
        %{cipher: :chacha20_poly1305, key_exchange: :ecdhe_rsa, mac: :aead, prf: :sha256},
        %{cipher: :aes_128_gcm, key_exchange: :dhe_rsa, mac: :aead, prf: :sha256},
        %{cipher: :aes_256_gcm, key_exchange: :dhe_rsa, mac: :aead, prf: :sha384}
      ]

    :ssl.filter_cipher_suites(preferred_ciphers, [])
  end

  defp protocol_versions do
    if otp_version() < 25 do
      [:"tlsv1.2"]
    else
      [:"tlsv1.2", :"tlsv1.3"]
    end
  end

  defp preferred_eccs do
    # TLS curves: X25519, prime256v1, secp384r1
    preferred_eccs = [:secp256r1, :secp384r1]
    :ssl.eccs() -- (:ssl.eccs() -- preferred_eccs)
  end

  # Certificates are verified unless TZWORLD_UNSAFE_HTTPS is set to something
  # other than an empty string, "false" or "nil", in any case. Verification
  # stays on for any value that says no, so a variable set to "false" cannot
  # turn it off.
  @doc false
  def secure_ssl? do
    value =
      @tzworld_unsafe_https
      |> System.get_env("")
      |> String.trim()
      |> String.downcase()

    value in ["", "false", "nil"]
  end

  defp https_proxy(options) do
    options[:https_proxy] ||
      Application.get_env(:tz_world, :https_proxy) ||
      System.get_env("HTTPS_PROXY") ||
      System.get_env("https_proxy")
  end

  @doc false
  def otp_version do
    :erlang.system_info(:otp_release) |> List.to_integer()
  end
end
