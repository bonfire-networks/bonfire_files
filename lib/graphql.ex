if Code.ensure_loaded?(Bonfire.GraphQL) do
defmodule Bonfire.Files.GraphQL do

  require Logger

  @uploader_fields %{
    image: Bonfire.Files.ImageUploader,
    icon: Bonfire.Files.IconUploader,
    document: Bonfire.Files.DocumentUploader,
  }

  def upload(user, %{} = params, _info) do
    params
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Enum.reduce_while(%{}, &do_upload(user, &1, &2))
    |> case do
      {:error, _} = e -> e
      val -> {:ok, Enum.into(val, %{})}
    end
  end

  defp do_upload(user, {field_name, %Absinthe.Blueprint.Input.String{value: url}}, acc) when is_binary(url) do
    # if we are getting a string rather than an object, assume its a URL
    do_upload(user, {field_name, url}, acc)
  end

  defp do_upload(user, {field_name, content_input}, acc) do
    uploader = @uploader_fields[field_name]

    if uploader do
      case Bonfire.Files.upload(uploader, user, content_input, %{}) do
        {:ok, media} ->
          field_id_name = String.to_existing_atom("#{field_name}_id")
          {:cont, Map.put(acc, field_id_name, media.id)}

        {:error, reason} ->
          # FIXME: delete other successful files on failure
          Logger.warn("Could not upload #{field_name}: #{reason}")

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
