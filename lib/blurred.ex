defmodule Bonfire.Files.Blurred do
  import Untangle
  alias Bonfire.Files.Media
  alias Bonfire.Common.Cache

  def blurhash_cached(%{metadata: %{blurhash: hash}}) when is_binary(hash) and hash != "" do
    hash
  end

  def blurhash_cached(%{metadata: %{"blurhash" => hash}}) when is_binary(hash) and hash != "" do
    hash
  end

  def blurhash_cached(%{file: %{metadata: %{blurhash: hash}}})
      when is_binary(hash) and hash != "" do
    hash
  end

  def blurhash_cached(%{file: %{metadata: %{"blurhash" => hash}}})
      when is_binary(hash) and hash != "" do
    hash
  end

  def blurhash_cached(_) do
    nil
  end

  def blurhash(media, opts \\ [])

  def blurhash(%{metadata: metadata, path: path, id: media_id} = media, opts) do
    if hash = blurhash_cached(media) do
      hash
    else
      case blurhash(path, opts) do
        nil ->
          "L6Pj0^jE.AyE_3t7t7R**0o#DgR4"

        # TODO: make fallback configurable
        hash ->
          # save it in DB 
          Media.update_by([id: media_id], metadata: Map.merge(metadata, %{blurhash: hash}))
          |> debug()

          hash
      end
    end
  end

  def blurhash(media_or_path, opts) do
    Cache.maybe_apply_cached(&make_blurhash/1, [
      (opts[:src] || media_or_path)
      |> String.trim_leading("/")
    ])
  end

  def make_blurhash(path) when is_binary(path) do
    with false <- String.starts_with?(path, "http"),
         {:ok, blurhash} <- Blurhash.downscale_and_encode(path, 4, 3) do
      # debug(blurhash, path)

      blurhash
    else
      e ->
        error(e, path)
        nil
    end
  end

  @doc "Create a blurred JPEG (deprecated in favour of blurhash)"
  def blurred(media_or_path, opts \\ [])
  def blurred(%{path: path} = _media, opts), do: blurred(path, opts)

  def blurred(original_path, opts) when is_binary(original_path) do
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

        if !opts[:skip_creation], do: make_blurred_jpeg(path, blurred_path, original_path)
      end
    end
  end

  defp make_blurred_jpeg(path, blurred_path, fallback) do
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
