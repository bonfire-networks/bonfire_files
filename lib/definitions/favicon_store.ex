# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.FaviconStore do
  @doc """
  Definition for storing media types for a URL
  """

  use Bonfire.Files.Definition
  import Where

  def favicon_url(url) when is_binary(url) and url !="" do
    with {:ok, path} <- cached_or_fetch(url) do
      # Files.data_url(image, meta.media_type)
      path
    else e ->
      error(e)
      nil
    end
  end
  def favicon_url(_), do: nil

  def cached_or_fetch("http"<>_ = url) do
    host = URI.parse(url).host
    if host && host !="" do
      filename = :crypto.hash(:sha256, host) |> Base.encode16
      path = "#{storage_dir()}/#{filename}"

      if File.exists?(path) do
        debug(host, "favicon already cached :)")
        {:ok, "/"<>path}
      else
        if File.exists?("#{storage_dir()}/#{filename}_none") do
          debug(host, "no favicon previously found")
          nil
        else
          debug(host, "first time, try finding a favicon for")
          fetch(url, filename, path)
        end
      end
    else
      {:error, "Invalid URL"}
    end
  end
  def cached_or_fetch(url), do: cached_or_fetch("https://"<>url)

  defp fetch(url, filename, path) do
    with {:ok, image} <- FetchFavicon.fetch(url),
         {:ok, filename} <- store(%{filename: filename, binary: image}),
         path <- ("#{storage_dir()}/#{filename}"),
         {:ok, file_info} <- Files.extract_metadata(path),
         :ok <- Files.verify_media_type(__MODULE__, file_info) do
          # Files.data_url(image, meta.media_type)
        {:ok, path}

      else e ->
        File.write("#{path}_none", "")
        e
    end
  end

  def storage_dir(_ \\ nil, _ \\ nil) do
    "data/uploads/favicons"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get_ext(:bonfire_files,
      [__MODULE__, :allowed_media_types], # allowed types for this definition
      ["image/png", "image/jpeg", "image/gif", "image/svg+xml", "image/tiff", "image/vnd.microsoft.icon"] # fallback
    )
  end

end
