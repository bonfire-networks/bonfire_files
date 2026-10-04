# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.FaviconSSRFTest do
  @moduledoc """
  `GET /files/favicon?url=` is public, so it must only fetch URLs the app generated itself (signed by `FaviconStore`), must never reach a private or loopback address, and must only store real raster images.

  The targets are real servers on loopback (`TestServer`): a refused fetch is proven by the server never being hit, and each refusal has a positive counterpart that fetches through the same path once its port is allowlisted. Faviconic's own tests cover redirects, icon links found in the page and the download size cap.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]
  @endpoint Application.compile_env!(:bonfire, :endpoint_module)

  alias Bonfire.Common.HTTP.TestServer
  alias Bonfire.Common.Text
  alias Bonfire.Files.FaviconStore

  @png File.read!(Bonfire.Files.Simulation.icon_file().path)

  setup do
    # the favicon cache is keyed by host only, so every server here shares one entry
    cached = "#{FaviconStore.storage_dir()}/#{Text.hash("127.0.0.1", algorithm: :sha)}"
    clear_cache = fn -> Enum.each([cached, "#{cached}.svg", "#{cached}_none"], &File.rm/1) end
    clear_cache.()
    on_exit(clear_cache)

    {:ok, conn: build_conn(), cached: cached}
  end

  # Starts a server answering `/favicon.ico` with `content_type` and `body` (any other path gets a 404), which reports each request it gets. Returns the server's URL.
  defp serve(content_type, body) do
    test_pid = self()

    port =
      TestServer.start(fn conn ->
        send(test_pid, {:hit, conn.request_path})

        case conn.request_path do
          "/favicon.ico" ->
            conn
            |> Plug.Conn.put_resp_content_type(content_type, nil)
            |> Plug.Conn.resp(200, body)

          _ ->
            Plug.Conn.resp(conn, 404, "")
        end
      end)

    "http://127.0.0.1:#{port}/"
  end

  defp serve_png, do: serve("image/png", @png)

  defp allow!(url) do
    %{host: host, port: port} = URI.parse(url)
    Process.put(:ssrf_allow_hosts, ["#{host}:#{port}"])
  end

  # the link the app itself renders, e.g. in `<img src=…>`
  defp app_link(url) do
    {:ok, "/files/favicon?" <> _ = link} = FaviconStore.cached_or_async_fetch_url(url)
    link
  end

  test "a URL the app didn't sign is refused without fetching it", %{conn: conn} do
    url = serve_png()
    allow!(url)

    conn = get(conn, "/files/favicon?" <> URI.encode_query(%{"url" => url}))

    assert conn.status == 403
    refute_receive {:hit, _}, 500
  end

  test "a signature for one URL doesn't work for another", %{conn: conn} do
    url = serve_png()
    allow!(url)

    %{"sig" => sig} =
      app_link("https://example.com/") |> URI.parse() |> Map.get(:query) |> URI.decode_query()

    conn = get(conn, "/files/favicon?" <> URI.encode_query(%{"url" => url, "sig" => sig}))

    assert conn.status == 403
    refute_receive {:hit, _}, 500
  end

  test "a signed URL is fetched and served once its host is allowed", %{
    conn: conn,
    cached: cached
  } do
    url = serve_png()
    allow!(url)

    conn = get(conn, app_link(url))

    assert_receive {:hit, "/favicon.ico"}
    assert redirected_to(conn) == "/" <> cached
    assert File.read!(cached) == @png
  end

  test "a signed URL to a loopback address is never fetched", %{conn: conn} do
    url = serve_png()

    conn = get(conn, app_link(url))

    assert conn.status == 404
    refute_receive {:hit, _}, 500
  end

  describe "only real images are stored" do
    test "an SVG is stored as .svg and served sandboxed, so its scripts can't run", %{
      conn: conn,
      cached: cached
    } do
      svg =
        ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(document.cookie)</script></svg>|

      url = serve("image/svg+xml", svg)
      allow!(url)

      conn = get(conn, app_link(url))

      assert_receive {:hit, "/favicon.ico"}
      assert redirected_to(conn) == "/#{cached}.svg"

      served = get(build_conn(), "/#{cached}.svg")
      assert served.resp_body == svg
      assert ["image/svg+xml" <> _] = get_resp_header(served, "content-type")
      assert [csp] = get_resp_header(served, "content-security-policy")
      assert csp =~ "sandbox"
    end

    test "a body that isn't an image is not stored, whatever its Content-Type says", %{
      conn: conn,
      cached: cached
    } do
      url = serve("image/png", ~s({"internal": "secret"}))
      allow!(url)

      conn = get(conn, app_link(url))

      assert_receive {:hit, "/favicon.ico"}
      assert conn.status == 404
      refute File.exists?(cached)
    end

    test "an image larger than the size limit is not stored", %{
      conn: conn,
      cached: cached
    } do
      url = serve_png()
      allow!(url)
      # in MB, so the fixture PNG is over the limit
      Process.put([:bonfire_files, :max_user_images_file_size], byte_size(@png) / 2 / 1_000_000)

      conn = get(conn, app_link(url))

      assert_receive {:hit, "/favicon.ico"}
      assert conn.status == 404
      refute File.exists?(cached)
    end
  end
end
