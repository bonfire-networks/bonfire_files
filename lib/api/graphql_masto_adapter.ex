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
              RestAdapter.json(conn, attachment(media))
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
            do_update_media(current_user, media, params, conn)

          _ ->
            RestAdapter.error_fn({:error, :not_found}, conn)
        end
      end
    end

    defp do_update_media(current_user, media, params, conn) do
      description = params["description"]
      focus = params["focus"]
      existing_metadata = media.metadata || %{}

      new_metadata =
        existing_metadata
        |> maybe_put("description", description)
        |> maybe_put("label", description)
        |> maybe_put("focus", focus)

      # `Media.update/4` checks the user may modify it (its creator or an admin); anyone else sees it as not found
      case Media.update(current_user, media, %{metadata: new_metadata}) do
        {:ok, updated_media} ->
          RestAdapter.json(conn, attachment(updated_media))

        {:error, :unauthorized} ->
          RestAdapter.error_fn({:error, :not_found}, conn)

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

      cond do
        is_nil(file) ->
          RestAdapter.error_fn({:error, "No file provided"}, conn)

        # the Mastodon API only takes a multipart upload: a string would otherwise be downloaded by the server if it's a URL (to any address), or read from the server's own disk if it's a path
        not is_struct(file, Plug.Upload) ->
          RestAdapter.error_fn(
            {:error, {:unprocessable_entity, "file must be a multipart file upload"}},
            conn
          )

        true ->
          metadata =
            %{}
            |> maybe_put("description", description)
            |> maybe_put("label", description)
            |> maybe_put("focus", focus)

          case Files.upload(
                 nil,
                 current_user,
                 file,
                 %{metadata: metadata, client_name: client_name(file)},
                 []
               ) do
            {:ok, media} ->
              RestAdapter.json(conn, attachment(media))

            {:error, reason} ->
              debug(reason, "Media upload failed")
              RestAdapter.error_fn({:error, reason}, conn)
          end
      end
    end

    # with what the stored file adds to the metadata (width, height, blurhash), which `meta` and `blurhash` are built from
    defp attachment(media),
      do: MediaAttachment.from_media(Map.put(media, :metadata, Media.metadata(media)))

    # the stored file is named after this and served by its extension, so it comes from the type detected in the bytes, not the client's name or `content_type` (`evil.html` holding an image is stored as `.png`); no extension when the type is unknown
    defp client_name(%Plug.Upload{path: path}) do
      with {:ok, %{media_type: media_type}} when is_binary(media_type) <-
             Files.extract_metadata(path),
           [ext | _] <- MIME.extensions(media_type) do
        "file.#{ext}"
      else
        _ -> "file"
      end
    end
  end
end
