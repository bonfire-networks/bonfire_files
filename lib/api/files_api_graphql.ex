# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Files.API.GraphQL do
    @moduledoc "Files/Media API fields/endpoints for GraphQL"

    use Absinthe.Schema.Notation
    use Absinthe.Relay.Schema.Notation, :modern
    use Bonfire.Common.Utils
    use Bonfire.Common.Repo
    import Untangle

    alias Absinthe.Resolution.Helpers
    alias Bonfire.API.GraphQL
    alias Bonfire.API.GraphQL.Pagination
    alias Bonfire.Common.Types
    alias Bonfire.Files
    alias Bonfire.Files.Media

    # Media object type
    object :media do
      field :id, non_null(:id)

      field :path, :string

      field :size, :integer

      field :media_type, :string

      field :metadata, :json

      field :creator, :any_character do
        resolve(Absinthe.Resolution.Helpers.dataloader(Needle.Pointer))
      end

      field :url, :string do
        resolve(fn media, _, _ ->
          {:ok, Files.full_url(nil, media)}
        end)
      end

      field :label, :string do
        resolve(fn media, _, _ ->
          {:ok, Media.media_label(media)}
        end)
      end

      field :description, :string do
        resolve(fn media, _, _ ->
          {:ok, Media.description(media)}
        end)
      end

      #   field(:activity, :activity, description: "An activity associated with this media")

      #   field(:activities, list_of(:activity),
      #     description: "All activities associated with this media (TODO)"
      #   )

      # TODO?
      #   field(:objects, list_of(:any_context),
      #     description: "All objects associated with this media"
      #   )
    end

    # Connection for pagination
    connection(node_type: :media)

    # Input types for filtering
    input_object :media_filter do
      field(:id, :id, description: "The ID of the media")
      field(:creator_id, :id, description: "Filter by creator ID")
      field(:media_type, :string, description: "Filter by media type (e.g., 'image/png')")

      field(:media_type_category, :string,
        description: "Filter by media type category (e.g., 'image', 'video', 'audio')"
      )
    end

    input_object :upload_input do
      field(:file, non_null(:upload), description: "The file to upload")
      field(:name, :string, description: "Optional name/label for the file")
      field(:description, :string, description: "Optional description")
    end

    input_object :uri_input do
      field(:uri, non_null(:string), description: "The URI/URL of the media to add")
      field(:name, :string, description: "Optional name/label for the media")
      field(:description, :string, description: "Optional description")
    end

    # Queries
    object :files_queries do
      @desc "Get a single media item by ID"
      field :media, :media do
        arg(:filter, :media_filter)
        resolve(&get_media/3)
      end

      @desc "Get media items with pagination and filtering"
      connection field :media_list, node_type: :media do
        arg(:filter, :media_filter)
        resolve(&list_media/3)
      end
    end

    # Mutations
    object :files_mutations do
      @desc "Upload a file"
      field :upload_media, :media do
        arg(:input, non_null(:upload_input))

        arg(:to_boundary, :string,
          description:
            "Boundary for visibility (e.g., 'public', 'local', 'mentions'). Defaults to nil (no activity published)"
        )

        arg(:to_circles, list_of(:id), description: "Circle IDs to publish to")
        resolve(&upload_media/2)
      end

      @desc "Add media by URI (get or insert - idempotent unless refetch_and_update is true)"
      field :add_media_by_uri, :media do
        arg(:input, non_null(:uri_input))

        arg(:refetch_and_update, :boolean,
          description:
            "Whether to refetch_and_update and update if URI already exists (default: false)"
        )

        arg(:to_boundary, :string,
          description:
            "Boundary for visibility (e.g., 'public', 'local', 'mentions'). Defaults to nil (no activity published)"
        )

        arg(:to_circles, list_of(:id), description: "Circle IDs to publish to")
        resolve(&add_media_by_uri/2)
      end

      @desc "Delete a media item"
      field :delete_media, :boolean do
        arg(:id, non_null(:id))
        resolve(&delete_media/2)
      end

      @desc "Update media metadata"
      field :update_media, :media do
        arg(:id, non_null(:id))
        arg(:name, :string)
        arg(:description, :string)
        resolve(&update_media/2)
      end
    end

    # Resolver functions

    def get_media(_parent, %{filter: %{id: id}}, _info) do
      Media.one(id: id)
    end

    def get_media(_parent, _args, _info) do
      {:error, "Media ID is required"}
    end

    def list_media(_parent, args, _info) do
      {pagination_args, filters} =
        Pagination.pagination_args_filter(args)
        |> debug("media list args")

      filter_opts = build_media_filters(e(filters, :filter, %{}))

      # Use the existing Queries module
      Media.Queries.query(Media, filter_opts)
      |> repo().many()
      |> case do
        media_list when is_list(media_list) ->
          Pagination.connection_paginate(
            {:ok, %{edges: media_list}},
            pagination_args
          )

        error ->
          error
      end
    end

    def upload_media(%{input: input} = args, info) do
      current_user = GraphQL.current_user(info)

      if current_user do
        with {:ok, media} <-
               Files.upload(
                 nil,
                 current_user,
                 input.file,
                 %{
                   metadata: %{
                     label: Map.get(input, :name),
                     description: Map.get(input, :description)
                   }
                 }
               ) do
          # Optionally publish as an activity if to_boundary or to_circles is provided
          to_boundary = Map.get(args, :to_boundary)
          to_circles = Map.get(args, :to_circles)

          if is_binary(to_boundary) or (is_list(to_circles) and to_circles != []) do
            publish_opts =
              []
              |> Keyword.put(:to_circles, to_circles)
              |> maybe_add_boundary(to_boundary)

            Media.publish(current_user, media, publish_opts)
          end

          {:ok, media}
        end
      else
        {:error, "Not authenticated"}
      end
    end

    def delete_media(%{id: id}, info) do
      current_user = GraphQL.current_user(info)

      if current_user do
        with {:ok, media} <- Media.one(id: id),
             # TODO: check permissions
             {:ok, _result} <- Media.hard_delete(nil, media) do
          {:ok, true}
        else
          {:error, _} = error -> error
          _ -> {:error, "Could not delete media"}
        end
      else
        {:error, "Not authenticated"}
      end
    end

    def update_media(%{id: id} = args, info) do
      current_user = GraphQL.current_user(info)

      if current_user do
        with {:ok, media} <- Media.one(id: id) do
          # TODO: check permissions
          updates = %{
            metadata: Map.merge(media.metadata || %{}, args |> Map.drop([:id]))
          }

          Media.update(current_user, media, updates)
        end
      else
        {:error, "Not authenticated"}
      end
    end

    def add_media_by_uri(%{input: input} = args, info) do
      if current_user = GraphQL.current_user(info) do
        opts =
          []
          |> Keyword.put(
            :update_existing,
            if(Map.get(args, :refetch_and_update), do: :force, else: false)
          )
          |> maybe_add_post_create_fn(
            current_user,
            Map.get(args, :to_boundary),
            Map.get(args, :to_circles)
          )
          |> maybe_add_extra_metadata(input)

        case Media.maybe_fetch_and_save(current_user, input.uri, opts) do
          %Media{} = media ->
            {:ok, media}

          {:ok, media} ->
            {:ok, media}

          {:error, reason} ->
            {:error, reason}

          nil ->
            {:error, "Could not fetch or save media from URI"}

          other ->
            error(other, "Unexpected return from maybe_fetch_and_save")
            {:error, "Could not process media URI"}
        end
      else
        {:error, "Not authenticated"}
      end
    end

    # Helper to add post_create_fn if to_boundary or to_circles is provided
    defp maybe_add_post_create_fn(opts, current_user, to_boundary, to_circles)
         when is_binary(to_boundary) or (is_list(to_circles) and to_circles != []) do
      Keyword.put(opts, :post_create_fn, fn user, media, _opts ->
        publish_opts =
          []
          |> Keyword.put(:to_circles, to_circles)
          |> maybe_add_boundary(to_boundary)

        Media.publish(user, media, publish_opts)

        # return media instead of post
        media
      end)
    end

    defp maybe_add_post_create_fn(opts, _current_user, _to_boundary, _to_circles), do: opts

    # Helper to add boundary if provided
    defp maybe_add_boundary(opts, boundary) when is_binary(boundary) do
      Keyword.put(opts, :boundary, boundary)
    end

    defp maybe_add_boundary(opts, _), do: opts

    # Helper to add extra metadata from input
    defp maybe_add_extra_metadata(opts, input) do
      extra =
        %{}
        |> Map.put("label", Map.get(input, :name))
        |> Map.put("description", Map.get(input, :description))
        |> Enums.filter_empty(%{})

      if map_size(extra) > 0 do
        Keyword.put(opts, :extra, extra)
      else
        opts
      end
    end

    # Helper to build filter options from GraphQL filter input
    defp build_media_filters(filter) when is_map(filter) do
      []
      |> maybe_add_filter(:id, Map.get(filter, :id))
      |> maybe_add_filter(:creator, Map.get(filter, :creator_id))
      |> maybe_add_media_type_filter(
        Map.get(filter, :media_type),
        Map.get(filter, :media_type_category)
      )
    end

    defp build_media_filters(_), do: []

    defp maybe_add_filter(filters, _key, nil), do: filters
    defp maybe_add_filter(filters, key, value), do: [{key, value} | filters]

    defp maybe_add_media_type_filter(filters, media_type, _category)
         when is_binary(media_type) do
      [{:media_type, media_type} | filters]
    end

    defp maybe_add_media_type_filter(filters, _media_type, category)
         when is_binary(category) do
      # Filter by media type category (e.g., "image" matches "image/png", "image/jpeg")
      # Note: The existing Queries module doesn't have media_type_like, so we'll need to add it
      # For now, just filter by exact media_type
      warn("Media type category filtering not yet implemented in Queries module")
      filters
    end

    defp maybe_add_media_type_filter(filters, _, _), do: filters
  end
end
