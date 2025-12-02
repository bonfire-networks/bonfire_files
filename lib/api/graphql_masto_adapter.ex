if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Files.API.GraphQLMasto.Adapter do
    @moduledoc """
    Media API adapter for Mastodon-compatible client apps.
    """

    use Bonfire.Common.Utils
    import Untangle

    alias Bonfire.API.GraphQL.RestAdapter
    alias Bonfire.API.MastoCompat.Mappers.MediaAttachment
    alias Bonfire.Files
    alias Bonfire.Files.Media

    def get_media(id, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        case fetch_media(id) do
          {:ok, media} ->
            if media.creator_id == id(current_user) do
              RestAdapter.json(conn, MediaAttachment.from_media(media))
            else
              RestAdapter.error_fn({:error, :not_found}, conn)
            end

          _ ->
            RestAdapter.error_fn({:error, :not_found}, conn)
        end
      end
    end

    defp fetch_media(id) do
      Media.one(id: id)
    rescue
      _ -> {:error, :not_found}
    end

    def update_media(id, params, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        case fetch_media(id) do
          {:ok, media} ->
            if media.creator_id == id(current_user) do
              do_update_media(media, params, conn)
            else
              RestAdapter.error_fn({:error, :not_found}, conn)
            end

          _ ->
            RestAdapter.error_fn({:error, :not_found}, conn)
        end
      end
    end

    defp do_update_media(media, params, conn) do
      description = params["description"]
      focus = params["focus"]
      existing_metadata = media.metadata || %{}

      new_metadata =
        existing_metadata
        |> maybe_put("description", description)
        |> maybe_put("label", description)
        |> maybe_put("focus", focus)

      case Media.update(nil, media, %{metadata: new_metadata}) do
        {:ok, updated_media} ->
          RestAdapter.json(conn, MediaAttachment.from_media(updated_media))

        {:error, reason} ->
          RestAdapter.error_fn({:error, reason}, conn)
      end
    end

    def upload_media(params, conn) do
      current_user = conn.assigns[:current_user]

      if is_nil(current_user) do
        RestAdapter.error_fn({:error, :unauthorized}, conn)
      else
        do_upload_media(current_user, params, conn)
      end
    end

    defp do_upload_media(current_user, params, conn) do
      file = params["file"]
      description = params["description"]
      focus = params["focus"]

      if is_nil(file) do
        RestAdapter.error_fn({:error, "No file provided"}, conn)
      else
        metadata =
          %{}
          |> maybe_put("description", description)
          |> maybe_put("label", description)
          |> maybe_put("focus", focus)

        case Files.upload(nil, current_user, file, %{metadata: metadata}, []) do
          {:ok, media} ->
            RestAdapter.json(conn, MediaAttachment.from_media(media))

          {:error, reason} ->
            debug(reason, "Media upload failed")
            RestAdapter.error_fn({:error, reason}, conn)
        end
      end
    end
  end
end
