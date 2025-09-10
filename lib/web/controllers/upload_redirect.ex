defmodule Bonfire.Files.Web.UploadRedirectController do
  use Bonfire.UI.Common.Web, :controller

  def call(
        %{params: %{"creator" => creator, "type" => type, "path" => path} = params} = conn,
        _params
      ) do
    with url when is_binary(url) <-
           maybe_redirect_url("/data/uploads/#{creator}/#{type}/#{path}", params["storage"]) do
      if target = params["target"] do
        info(
          from_ok(Base.url_decode64(target)) || target,
          "Redirecting to #{type} URL for #{path} by #{creator} in storage #{params["storage"]} for target"
        )
      end

      conn
      |> redirect_to(url, type: :maybe_external)
    else
      e ->
        error(e, "Could not generate URL for upload")

        Plug.Conn.send_resp(conn, 404, "Could not generate URL for upload")
    end
  end

  def call(%{params: %{"path" => path} = params} = conn, _params) do
    with url when is_binary(url) <- maybe_redirect_url(path, params["storage"]) do
      if target = params["target"] do
        info(
          from_ok(Base.url_decode64(target)) || target,
          "Redirecting to upload URL for #{path} in storage #{params["storage"]} for target"
        )
      end

      conn
      |> redirect_to(url, type: :maybe_external)
    else
      e ->
        error(e, "Could not generate URL for upload")

        Plug.Conn.send_resp(conn, 404, "Could not generate URL for upload")
    end
  end

  def call(conn, _params) do
    Plug.Conn.send_resp(conn, 404, l("Not found"))
  end

  def maybe_redirect_url(path, storage) when is_list(path) do
    Path.join(path)
    |> maybe_redirect_url(storage)
  end

  def maybe_redirect_url(path, storage) do
    # TODO: check permissions?
    Bonfire.Files.cached_entrepot_storage_url(path, storage)
  end
end
