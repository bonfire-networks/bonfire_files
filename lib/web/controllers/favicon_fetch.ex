defmodule Bonfire.Files.Web.FaviconFetchController do
  use Bonfire.UI.Common.Web, :controller

  alias Bonfire.Files.FaviconStore

  # a public route, so it only fetches URLs the app signed itself (see `FaviconStore.sign/1`)
  def call(%{params: %{"url" => url} = params} = conn, _params) do
    debug(url)

    if FaviconStore.valid_signature?(url, params["sig"]) do
      with {:ok, path} <- FaviconStore.cached_or_fetch(url) do
        conn
        |> redirect_to(path)
      else
        e ->
          error(e)

          Plug.Conn.send_resp(conn, 404, "")
      end
    else
      Plug.Conn.send_resp(conn, 403, "")
    end
  end

  def call(conn, _params) do
    Plug.Conn.send_resp(conn, 404, "")
  end
end
