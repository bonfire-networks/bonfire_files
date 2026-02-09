if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Files.Web.MastoMediaController do
    @moduledoc "Mastodon-compatible Media REST endpoints."

    use Bonfire.UI.Common.Web, :controller

    alias Bonfire.Files.API.GraphQLMasto.Adapter

    def show(conn, %{"id" => id}), do: Adapter.get_media(id, conn)
    def update(conn, %{"id" => id} = params), do: Adapter.update_media(id, params, conn)
    def create(conn, params), do: Adapter.upload_media(params, conn)
    def create_v2(conn, params), do: Adapter.upload_media(params, conn)
  end
end
