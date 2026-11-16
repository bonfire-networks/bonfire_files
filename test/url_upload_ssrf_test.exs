# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.UrlUploadSSRFTest do
  @moduledoc """
  Media added by URL is downloaded through the same SSRF guard as other fetches: a private or loopback host is never contacted unless its `host:port` is in the `ssrf_allow_hosts` allowlist.

  The site is a real HTTP server on this machine (`TestServer`). A test that expects a refusal checks that the server never received a request, and the control test with the host allowlisted checks that the same fetch does arrive, which shows it really would have been made. `skip_fetching_remote: false` makes the upload download the URL even in the test environment, which otherwise only stores the URL.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Common.HTTP.TestServer
  alias Bonfire.Files

  @png File.read!(Bonfire.Files.Simulation.icon_file().path)

  setup do
    test_pid = self()

    # the test env mocks the HTTP adapter, so the downloads here would never reach the real listener
    previous_adapter = Application.get_env(:tesla, :adapter)
    Application.put_env(:tesla, :adapter, {Tesla.Adapter.Finch, name: Bonfire.Finch})

    on_exit(fn ->
      if previous_adapter,
        do: Application.put_env(:tesla, :adapter, previous_adapter),
        else: Application.delete_env(:tesla, :adapter)
    end)

    port =
      TestServer.start(fn conn ->
        send(test_pid, {:hit, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("image/png", nil)
        |> Plug.Conn.resp(200, @png)
      end)

    {:ok, me: fake_user!(), url: "http://127.0.0.1:#{port}/i.png", host_port: "127.0.0.1:#{port}"}
  end

  defp upload(me, url), do: Files.upload(nil, me, url, %{}, skip_fetching_remote: false)

  test "control: a loopback host in the allowlist is fetched", %{
    me: me,
    url: url,
    host_port: host_port
  } do
    Process.put(:ssrf_allow_hosts, [host_port])

    upload(me, url)

    assert_receive {:hit, "/i.png"}, 2_000
  end

  # a second listener that answers every request with a 302 to the given location
  defp redirecting_server(location) do
    test_pid = self()

    port =
      TestServer.start(fn conn ->
        send(test_pid, {:redirector_hit, conn.request_path})

        conn
        |> Plug.Conn.put_resp_header("location", location)
        |> Plug.Conn.resp(302, "")
      end)

    {"http://127.0.0.1:#{port}/r.png", "127.0.0.1:#{port}"}
  end

  test "a redirect from an allowlisted host to a host that is not allowlisted is refused, and the target gets no request",
       %{me: me, url: target_url} do
    {redirect_url, redirect_host_port} = redirecting_server(target_url)
    Process.put(:ssrf_allow_hosts, [redirect_host_port])

    result = upload(me, redirect_url)

    assert_receive {:redirector_hit, "/r.png"}, 2_000
    refute_receive {:hit, _}, 500
    refute match?({:ok, %{size: size}} when size > 0, result)
  end

  test "control: a redirect to an allowlisted host is followed and the file is stored", %{
    me: me,
    url: target_url,
    host_port: host_port
  } do
    {redirect_url, redirect_host_port} = redirecting_server(target_url)
    Process.put(:ssrf_allow_hosts, [redirect_host_port, host_port])

    result = upload(me, redirect_url)

    assert_receive {:redirector_hit, "/r.png"}, 2_000
    assert_receive {:hit, "/i.png"}, 2_000
    assert {:ok, %{size: size}} = result
    assert size > 0
  end

  test "an `Entrepot.Upload` of a `%URI{}` to a loopback host that is not allowlisted is refused, with no request made",
       %{url: url} do
    # the library fetches through our client only when configured to
    assert Application.get_env(:entrepot, :uri_fetcher) == {Bonfire.Files, :fetch_body},
           "`:entrepot, :uri_fetcher` is #{inspect(Application.get_env(:entrepot, :uri_fetcher))}"

    # the same check the fetch goes through, on its own
    assert {:error, _} = Bonfire.Common.HTTP.SSRF.check(url),
           "the SSRF check lets #{url} through (allowlist: #{inspect(Application.get_env(:bonfire_common, :ssrf_allow_hosts))}, ssrf config: #{inspect(Application.get_env(:bonfire_common, :ssrf))})"

    assert {:error, _} = Entrepot.Upload.contents(URI.parse(url))

    refute_receive {:hit, _}, 500
  end

  test "control: an `Entrepot.Upload` of a `%URI{}` to an allowlisted host is fetched", %{
    url: url,
    host_port: host_port
  } do
    Process.put(:ssrf_allow_hosts, [host_port])

    assert {:ok, @png} = Entrepot.Upload.contents(URI.parse(url))
    assert_receive {:hit, "/i.png"}, 2_000
  end

  test "a loopback host that is not in the allowlist is never fetched", %{me: me, url: url} do
    result = upload(me, url)

    refute_receive {:hit, _}, 500
    refute match?({:ok, %{size: size}} when size > 0, result)
  end
end
