defmodule Bonfire.Files.Blurred do
  import Untangle
  alias Bonfire.Common.Cache

  def blurred(definition \\ nil, media_or_path)
  def blurred(definition, %{path: path} = _media), do: blurred(definition, path)

  def blurred(_definition, original_path) when is_binary(original_path) do
    path = String.trim_leading(original_path, "/")
    blurred_path = path <> "_preview.jpg"

    if String.starts_with?(path, "http") or
         String.ends_with?(path, [".gif", ".gifv"]) or is_nil(path) or
         path == "" or not File.exists?(path) or System.get_env("CI") do
      debug(
        path,
        "it's either an external media, invalid file, or a gif (currently not supported), so just use the original"
      )

      original_path
    else
      if File.exists?(blurred_path) do
        debug(blurred_path, "blurred jpeg already exists :)")
        "/#{blurred_path}"
      else
        debug(path, "first time trying to get this blurred image?")

        make_blurred_jpeg(path, blurred_path, original_path)

      end
    end
  end
  
  def blurhash(path, fallback \\ nil) do
    Cache.maybe_apply_cached(&make_blurhash/2, [path, fallback])
  end

  def make_blurhash(path, fallback \\ nil) do
    path = String.trim_leading(path, "/")

    with false <- String.starts_with?(path, "http"),
    {:ok, blurhash} <- Blurhash.downscale_and_encode(path, 4, 3) do
      debug(blurhash, path)

      # TODO: save it in DB or cache

      blurhash
    else
      e ->
        error(e, path)
        fallback
    end
  end

  defp make_blurred_jpeg(path, blurred_path, fallback \\ nil) do
        with saved_path when is_binary(saved_path) <-
            Bonfire.Files.Image.Edit.blur(path, blurred_path),
          true <- File.exists?(saved_path) do
      debug(saved_path, "saved blurred jpeg")

      "/#{saved_path}"
    else
      e ->
        error(e)
        fallback
    end
  end
end
