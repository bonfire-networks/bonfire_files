if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Files.Web.MastoMediaController do
    @moduledoc "Mastodon-compatible Media REST endpoints."

    use Bonfire.UI.Common.Web, :controller
    import Untangle

    alias Bonfire.Files.API.GraphQLMasto.Adapter

    def show(conn, %{"id" => id} = params) do
      debug(params, "GET /api/v1/media/#{id}")
      Adapter.get_media(id, conn)
    end

    def update(conn, %{"id" => id} = params) do
      debug(params, "PUT /api/v1/media/#{id}")
      Adapter.update_media(id, params, conn)
    end

    def create(conn, params) do
      debug(params, "POST /api/v1/media")
      Adapter.upload_media(params, conn)
    end

    def create_v2(conn, params) do
      debug(params, "POST /api/v2/media")
      Adapter.upload_media(params, conn)
    end
  end
end
