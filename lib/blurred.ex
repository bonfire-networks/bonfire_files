defmodule Bonfire.Files.Blurred do
  import Where

  def blurred(definition \\ nil, media_or_path)
  def blurred(definition, %{path: path} = _media), do: blurred(definition, path)
  def blurred(_definition, path) when is_binary(path) do

    path = String.trim_leading(path, "/")
    final_path = path<>"_preview.jpg"

    ret_path = if String.starts_with?(path, "http") or is_nil(path) or path =="" or not File.exists?(path) or System.get_env("CI") do
      debug(path, "it's an external or invalid image, skip")
      path
    else
      if File.exists?(final_path) do
        debug(final_path, "blurred jpeg already exists :)")
        final_path
      else
        debug(final_path, "first time trying to get this blurred jpeg?")

        with saved_path when is_binary(saved_path) <- Bonfire.Files.Image.Edit.blur(path, final_path) do

            debug(saved_path, "saved blurred jpeg")

            saved_path
          else e ->
            error(e)
            path
        end
      end
    end

    "/#{ret_path}"
  end


end
