# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.FaviconStore do
  @doc """
  Definition for storing media types for a URL
  """

  # use Bonfire.Files.Definition # NOTE: not using entrepot to keep it simple and store files on disk for now

  use Bonfire.Common.Config
  alias Bonfire.Common.Text
  alias Bonfire.Files
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

      if path = cached_path(filename) do
        debug(host, "favicon already cached :)")
        {:ok, "/" <> path}
      else
        if File.exists?("#{storage_dir()}/#{filename}_none") do
          debug(host, "no favicon previously found")
          nil
        else
          debug(host, "first time, return URL to FaviconController to try fetching it async")
          {:ok, "/files/favicon?" <> URI.encode_query(%{"url" => url, "sig" => sign(url)})}
        end
      end
    else
      {:error, "Invalid URL"}
    end
  end

  @doc """
  Signs a favicon URL, so `FaviconFetchController` (a public route) only fetches URLs the app generated itself. Deterministic, so the same link stays cacheable across page renders.
  """
  def sign(url) when is_binary(url) do
    :crypto.mac(:hmac, :sha256, secret_key_base(), "favicon:" <> url)
    |> Base.url_encode64(padding: false)
  end

  def valid_signature?(url, sig) when is_binary(url) and is_binary(sig),
    do: Plug.Crypto.secure_compare(sign(url), sig)

  def valid_signature?(_, _), do: false

  defp secret_key_base, do: Bonfire.Common.Config.endpoint_module().config(:secret_key_base)

  # SVGs are stored with their extension so they're served as `image/svg+xml` (sandboxed by the CSP on `/data/uploads/`), raster images without one
  defp cached_path(filename) do
    path = "#{storage_dir()}/#{filename}"
    Enum.find([path, path <> ".svg"], &File.exists?/1)
  end

  def cached_or_fetch(url, opts \\ [])

  def cached_or_fetch(url, opts) do
    debug(url, "lookup for url")
    host = URI.parse(url).host

    if host && host != "" do
      filename = Text.hash(host, algorithm: :sha)
      path = "#{storage_dir()}/#{filename}"

      if cached = cached_path(filename) do
        debug(host, "favicon already cached :)")
        {:ok, "/" <> cached}
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
    with {:ok, image} <- Faviconic.fetch(url),
         {:ok, extension} <- check_image(image),
         path <- "#{storage_dir()}/#{filename}#{extension}",
         #  {:ok, filename} <- store(%{filename: filename, binary: image}),
         :ok <- File.write(path, image) do
      # Files.data_url(image, meta.media_type)
      {:ok, "/" <> path}
    else
      e ->
        File.write("#{path}_none", "")
        e
    end
    |> debug()
  end

  # Faviconic only checks the Content-Type the remote server declares, so check the bytes themselves before storing them on our origin. Returns the file extension to store with.
  defp check_image(image) do
    with true <- byte_size(image) <= max_file_size() || {:error, :too_large},
         {:ok, %{media_type: type}} when is_binary(type) <- TwinkleStar.from_bytes(image),
         type = Bonfire.Files.MimeTypes.normalize_type(type),
         true <- type in allowed_media_types() || {:error, {:unsupported_media_type, type}} do
      {:ok, if(type == "image/svg+xml", do: ".svg", else: "")}
    end
  end

  def storage_dir(_ \\ nil, _ \\ nil) do
    "data/uploads/#{prefix_dir()}"
  end

  def prefix_dir() do
    "favicons"
  end

  @impl true
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

  @impl true
  def max_file_size do
    Files.normalise_size(
      Bonfire.Common.Config.get([:bonfire_files, :max_user_images_file_size]),
      1
    )
  end
end
