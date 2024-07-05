# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.FaviconStore do
  @doc """
  Definition for storing media types for a URL
  """

  use Bonfire.Files.Definition
  alias Bonfire.Common.Text
  import Untangle

  def favicon_url(url, opts \\ [])

  def favicon_url("http" <> _ = url, opts) do
    with {:ok, path} <- cached_or_async_fetch_url(url, opts) do
      # Files.data_url(image, meta.media_type)
      path
    else
      e ->
        error(e)
        nil
    end
  end

  def favicon_url(url, opts) when is_binary(url) and url != "",
    do: cached_or_fetch("https://#{url}", opts)

  def favicon_url(_, _), do: nil

  def cached_or_async_fetch_url(url, opts \\ [])

  def cached_or_async_fetch_url(url, opts) do
    info(url, "url")
    host = URI.parse(url).host

    if host && host != "" do
      filename = Text.hash(host, algorithm: :sha)
      path = "#{storage_dir()}/#{filename}"

      if File.exists?(path) do
        debug(host, "favicon already cached :)")
        {:ok, "/" <> path}
      else
        if File.exists?("#{storage_dir()}/#{filename}_none") do
          debug(host, "no favicon previously found")
          nil
        else
          debug(host, "first time, return URL to FaviconController to try fetching it async")
          {:ok, "/favicon_fetch?url=#{url}"}
        end
      end
    else
      {:error, "Invalid URL"}
    end
  end

  def cached_or_fetch(url, opts \\ [])

  def cached_or_fetch(url, opts) do
    debug(url, "lookup for url")
    host = URI.parse(url).host

    if host && host != "" do
      filename = Text.hash(host, algorithm: :sha)
      path = "#{storage_dir()}/#{filename}"

      if File.exists?(path) do
        debug(host, "favicon already cached :)")
        {:ok, "/" <> path}
      else
        path_if_none = "#{path}_none"

        if File.exists?(path_if_none) do
          debug(path_if_none, "no favicon found previously, skip")
          nil
        else
          debug(host, "first time, try finding a favicon for")
          fetch(url, filename, path, opts)
        end
      end
    else
      {:error, "Invalid URL"}
    end
  end

  defp fetch(url, filename, path, _opts) do
    with {:ok, image} <- FetchFavicon.fetch(url),
         {:ok, filename} <- store(%{filename: filename, binary: image}),
         path <- "#{storage_dir()}/#{filename}" do
      # Files.data_url(image, meta.media_type)
      {:ok, "/" <> path}
    else
      e ->
        File.write("#{path}_none", "")
        e
    end
    |> debug()
  end

  def storage_dir(_ \\ nil, _ \\ nil) do
    "data/uploads/#{prefix_dir()}"
  end

  def prefix_dir() do
    "favicons"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      # allowed types for this definition
      [__MODULE__, :allowed_media_types],
      # fallback
      [
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/svg+xml",
        "image/tiff",
        "image/vnd.microsoft.icon"
      ]
    )
  end

  def max_file_size do
    Files.normalise_size(
      Bonfire.Common.Config.get([:bonfire_files, :max_user_images_file_size]),
      1
    )
  end
end
