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
