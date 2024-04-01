if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Files.GraphQL do
    import Untangle

    @uploader_fields %{
      image: Bonfire.Files.ImageUploader,
      icon: Bonfire.Files.IconUploader,
      document: Bonfire.Files.DocumentUploader
    }

    def upload(creator, %{} = params, _info) do
      params
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.reduce_while(%{}, &do_upload(creator, &1, &2))
      |> case do
        {:error, _} = e -> e
        val -> {:ok, Enum.into(val, %{})}
      end
    end

    def upload(creator, _params, _info) do
      {:ok, %{}}
    end

    defp do_upload(
           creator,
           {field_name, %Absinthe.Blueprint.Input.String{value: url}},
           acc
         )
         when is_binary(url) do
      debug(
        "Bonfire.Files.GraphQL.upload - we are getting a string rather than an object, so assume its a URL"
      )

      do_upload(creator, {field_name, url}, acc)
    end

    defp do_upload(creator, {field_name, content_input}, acc) do
      uploader = @uploader_fields[field_name]

      if uploader do
        debug(
          "Bonfire.Files.GraphQL.upload - attempt to upload: #{inspect(field_name)} - #{inspect(content_input)}"
        )

        case Bonfire.Files.upload(uploader, creator, content_input, %{}) do
          {:ok, media} ->
            field_id_name = String.to_existing_atom("#{field_name}_id")
            {:cont, Map.put(acc, field_id_name, media.id)}

          {:error, reason} ->
            # FIXME: delete other successful files on failure
            warn("Could not upload #{field_name}: #{reason}")

            {:halt, {:error, reason}}

          _ ->
            {:cont, acc}
        end
      else
        {:cont, acc}
      end
    end
  end
end
