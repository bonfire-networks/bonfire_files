defmodule Bonfire.Files.Web.FaviconFetchController do
  use Bonfire.UI.Common.Web, :controller

  def call(%{params: %{"url" => url}} = conn, _params) do
    debug(url)

    with {:ok, path} <- Bonfire.Files.FaviconStore.cached_or_fetch(url) do
      conn
      |> redirect_to(path)
    else
      e ->
        error(e)

        Plug.Conn.send_resp(conn, 404, "")
    end
  end

  def call(conn, _params) do
    Plug.Conn.send_resp(conn, 404, "")
  end
end
