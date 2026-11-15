if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Files.API.GraphQL.MediaTest do
    use Bonfire.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema

    @moduletag :graphql

    @media_type_query """
    query {
      __type(name: "Media") {
        fields {
          name
          type {
            kind
            name
            ofType {
              kind
              name
            }
          }
        }
      }
    }
    """

    @upload_media """
    mutation($file: Upload!, $description: String!) {
      upload_media(input: {file: $file, description: $description}) {
        id
        description
        metadata
      }
    }
    """

    test "Media.id is nullable in the public GraphQL schema" do
      {:ok, result} = Absinthe.run(@media_type_query, Schema)

      refute result[:errors]

      media_id_field =
        result
        |> get_in([:data, "__type", "fields"])
        |> Enum.find(&(&1["name"] == "id"))

      assert get_in(media_id_field, ["type", "kind"]) == "SCALAR"
      assert get_in(media_id_field, ["type", "name"]) == "ID"
    end

    test "uploadMedia exposes the user supplied description and stores it as alt metadata" do
      user = fake_user!()
      description = "GraphQL upload alt text"

      upload = %Plug.Upload{
        path: Path.expand("../fixtures/150.png", __DIR__),
        filename: "graphql-upload.png",
        content_type: "image/png"
      }

      {:ok, result} =
        Absinthe.run(@upload_media, Schema,
          variables: %{"file" => "graphql-upload", "description" => description},
          context:
            Schema.context(%{current_user: user})
            |> Map.put(:__absinthe_plug__, %{uploads: %{"graphql-upload" => upload}})
        )

      refute result[:errors]

      media = get_in(result, [:data, "upload_media"])
      assert is_binary(media["id"]) and media["id"] != ""
      assert media["description"] == description
      assert metadata_value(media["metadata"], "description") == description
      assert metadata_value(media["metadata"], "alt") == description
    end

    @add_media_by_uri """
    mutation($uri: String!) {
      add_media_by_uri(input: {uri: $uri}) {
        id
      }
    }
    """

    describe "add_media_by_uri" do
      setup do
        test_pid = self()

        Tesla.Mock.mock(fn env ->
          send(test_pid, {:hit, env.url})

          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "text/html"}],
            body: "<html><head><title>Example page</title></head></html>"
          }
        end)

        :ok
      end

      defp add_media_by_uri(uri) do
        Absinthe.run(@add_media_by_uri, Schema,
          variables: %{"uri" => uri},
          context: Schema.context(%{current_user: fake_user!()})
        )
      end

      test "adds a media item for a URI, fetching its page" do
        {:ok, result} = add_media_by_uri("https://example.com/article")

        refute result[:errors]
        assert is_binary(get_in(result, [:data, "add_media_by_uri", "id"]))
        assert_received {:hit, "https://example.com/article"}
      end

      test "never fetches a URI on a private address" do
        add_media_by_uri("http://10.0.0.1/admin")

        refute_received {:hit, "http://10.0.0.1" <> _}
      end
    end

    describe "add_media_by_uri refetch_and_update on a URI someone else already added" do
      @refetch_media_by_uri """
      mutation($uri: String!, $name: String!) {
        add_media_by_uri(input: {uri: $uri, name: $name}, refetch_and_update: true) {
          id
        }
      }
      """

      setup do
        Tesla.Mock.mock(fn _env ->
          %Tesla.Env{
            status: 200,
            headers: [{"content-type", "text/html"}],
            body: "<html><head><title>Shared page</title></head></html>"
          }
        end)

        uri = "https://example.com/shared-#{System.unique_integer([:positive])}"
        owner = fake_user!()

        {:ok, result} =
          Absinthe.run(@refetch_media_by_uri, Schema,
            variables: %{"uri" => uri, "name" => "Owner's label"},
            context: Schema.context(%{current_user: owner})
          )

        refute result[:errors]
        assert {:ok, media} = Bonfire.Files.Media.get_by_path(uri)
        assert media.metadata["label"] == "Owner's label"

        {:ok, uri: uri, owner: owner, other: fake_user!()}
      end

      defp label_of(uri) do
        {:ok, media} = Bonfire.Files.Media.get_by_path(uri)
        media.metadata["label"]
      end

      test "the owner can change their media's label", %{uri: uri, owner: owner} do
        Absinthe.run(@refetch_media_by_uri, Schema,
          variables: %{"uri" => uri, "name" => "Renamed by owner"},
          context: Schema.context(%{current_user: owner})
        )

        assert label_of(uri) == "Renamed by owner"
      end

      test "another user can't overwrite it", %{uri: uri, other: other} do
        Absinthe.run(@refetch_media_by_uri, Schema,
          variables: %{"uri" => uri, "name" => "Changed by someone else"},
          context: Schema.context(%{current_user: other})
        )

        assert label_of(uri) == "Owner's label"
      end
    end

    describe "someone else's media" do
      @delete_media """
      mutation($id: ID!) {
        delete_media(id: $id)
      }
      """

      @update_media """
      mutation($id: ID!, $name: String!) {
        update_media(id: $id, name: $name) {
          id
        }
      }
      """

      setup do
        owner = fake_user!()
        other = fake_user!()

        upload = %Plug.Upload{
          path: Path.expand("../fixtures/150.png", __DIR__),
          filename: "graphql-owned.png",
          content_type: "image/png"
        }

        {:ok, result} =
          Absinthe.run(@upload_media, Schema,
            variables: %{"file" => "graphql-owned", "description" => "Owner's alt text"},
            context:
              Schema.context(%{current_user: owner})
              |> Map.put(:__absinthe_plug__, %{uploads: %{"graphql-owned" => upload}})
          )

        refute result[:errors]
        media_id = get_in(result, [:data, "upload_media", "id"])
        assert {:ok, media} = Bonfire.Files.Media.one(id: media_id)

        {:ok, owner: owner, other: other, media: media}
      end

      test "its owner can delete it", %{owner: owner, media: media} do
        Absinthe.run(@delete_media, Schema,
          variables: %{"id" => media.id},
          context: Schema.context(%{current_user: owner})
        )

        assert {:error, :not_found} = Bonfire.Files.Media.one(id: media.id)
      end

      test "its owner can update it", %{owner: owner, media: media} do
        {:ok, result} =
          Absinthe.run(@update_media, Schema,
            variables: %{"id" => media.id, "name" => "Changed by owner"},
            context: Schema.context(%{current_user: owner})
          )

        refute result[:errors]
        assert {:ok, updated} = Bonfire.Files.Media.one(id: media.id)
        assert metadata_value(updated.metadata, "name") == "Changed by owner"
      end

      test "a user can't delete it", %{other: other, media: media} do
        Absinthe.run(@delete_media, Schema,
          variables: %{"id" => media.id},
          context: Schema.context(%{current_user: other})
        )

        assert {:ok, _} = Bonfire.Files.Media.one(id: media.id),
               "a user deleted media uploaded by someone else"
      end

      test "a user can't update it", %{other: other, media: media} do
        refute Map.has_key?(media.metadata, "name")

        Absinthe.run(@update_media, Schema,
          variables: %{"id" => media.id, "name" => "Changed by someone else"},
          context: Schema.context(%{current_user: other})
        )

        assert {:ok, updated} = Bonfire.Files.Media.one(id: media.id)

        refute Map.has_key?(updated.metadata, "name"),
               "a user changed the metadata of media uploaded by someone else"
      end
    end

    defp metadata_value(metadata, key) when is_map(metadata) do
      Enum.find_value(metadata, fn
        {^key, value} ->
          value

        {metadata_key, value} when is_atom(metadata_key) ->
          if Atom.to_string(metadata_key) == key, do: value

        _ ->
          nil
      end)
    end
  end
end
