# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files do
  @moduledoc """
  An uploader definition must be provided for each new upload.

  A few uploaders exist as defaults inside of this namespace, but you can also define
  your own.

  ```elixir
  defmodule MyUploader do
    use Bonfire.Files.Definition

    @versions [:original, :thumb]

    def transform(:thumb, _) do
      {:convert, "-thumbnail 100x100 -format png", :png}
    end

    def filename(version, _) do
      version
    end

    def storage_dir(_, {file, user_id}) do
      "uploads/my/" <> user_id
    end

    def allowed_media_types do
      ["image/png", "image/jpeg"]
    end
  end
  ```

  You may have noticed that this definition is very similar to what a definition
  would look like in [waffle](https://github.com/elixir-waffle/waffle).
  A `Bonfire.Files.Definition` is functionally the same as a `Waffle.Definition`,
  however the `allowed_media_types/0` callback is added, forcing you to define
  what media types are accepted for these types of uploads.
  (You can also return `:all` to accept everything).

  To use the uploader:

  ```
  iex> {:ok, media} = Bonfire.Files.upload(MyUploader, user, %{path: "./150.png"})
  iex> media.media_type
  "image/png"
  iex> Bonfire.Files.remote_url(MyUploader, media)
  "/uploads/my/01F3AY6JV30G06BY4DR9BTW5EH"
  ```
  """
  import Where
  alias Ecto.Changeset
  alias Bonfire.Repo
  alias Bonfire.Common.Utils

  alias Bonfire.Files.{
    Media,
    FileDenied,
    Queries
  }

  def one(filters), do: Repo.single(Queries.query(Media, filters))

  def many(filters \\ []), do: {:ok, Repo.many(Queries.query(Media, filters))}

  @doc """
  Attempt to store a file, returning an upload, for any parent item that
  participates in the meta abstraction, providing the user responsible for
  the upload.
  """

  def upload(module, user, file, attrs \\ %{}, opts \\ [])

  def upload(module, user, file, attrs, opts) when is_binary(file) and is_atom(module) and not is_nil(module) do
    if opts[:skip_fetching_remote]==true or ( Bonfire.Common.Config.get!(:env) == :test and String.starts_with?(file, "http") ) do
      debug("Files - skip file handling and just insert url or path in DB")
      insert_media(user, %{path: file}, %{size: 0, media_type: "remote"}, attrs)
    else
      do_upload(module, user, file, attrs, opts)
    end
  end
  def upload(module, user, file, attrs, opts) when is_atom(module) and not is_nil(module), do: do_upload(module, user, file, attrs, opts)

  def do_upload(module, user, file, attrs, opts) do
    with {:ok, file} <- fetch_file(module, file),
          {:ok, file_info} <- extract_metadata(file),
          :ok <- verify_media_type(module, file_info),
          {:ok, new_path} <- module.store({file.path, Utils.ulid(user)}) do
      insert_media(user, %{file | path: new_path}, file_info, attrs)

    else
      other ->
        error(other)
    end
  end

  defp insert_media(user, %{path: path} = file, file_info, attrs) do
    attrs =
      attrs
      |> Map.put(:path, path)
      |> Map.put(:size, file_info[:size])
      |> Map.put(:media_type, file_info[:media_type])

    with {:ok, media} <- Repo.insert(Media.changeset(user, attrs)) do
      {:ok,
        media
        |> Map.put(:user, user)
        |> Map.put(:file, file)
      }
    end
    #|> debug
  end

  @doc """
  Return the URL that a local file has.
  """
  @spec remote_url(atom, Media.t()) :: binary
  def remote_url(module, media, version \\ nil)

  def remote_url(module, %Media{} = media, version),
    do: module.url({media.path, media.user_id}, version)

  def remote_url(module, media_id, version) when is_binary(media_id) do
    case __MODULE__.one(id: media_id) do
      {:ok, media} ->
        remote_url(module, media, version)

      _ ->
        nil
    end
  end

  def remote_url(_, _, _), do: nil

  def update_by(filters, updates) do
    Repo.update_all(Queries.query(Media, filters), set: updates)
  end

  @doc """
  Delete an upload, removing it from indexing, but the files remain available.
  """
  @spec soft_delete(Media.t()) :: {:ok, Media.t()} | {:error, Changeset.t()}
  def soft_delete(%Media{} = media) do
    Bonfire.Repo.Delete.soft_delete(media)
  end

  @doc """
  Delete an upload, removing any associated files.
  """
  @spec hard_delete(atom, Media.t()) :: :ok | {:error, Changeset.t()}
  def hard_delete(module, %Media{} = media) do
    resp =
      Repo.transaction(fn ->
        with {:ok, media} <- Repo.delete(media),
             {:ok, _} <- module.delete({media.path, media.user_id}) do
          :ok
        end
      end)

    with {:ok, v} <- resp, do: v
  end

  @doc false
  def hard_delete() do
    delete_by(deleted: true)
  end

  # FIXME: doesn't cleanup files
  defp delete_by(filters) do
    Queries.query(Media)
    |> Queries.filter(filters)
    |> Repo.delete_all()
  end

  defp fetch_file(module, file) do
    file
    |> Bonfire.Common.Utils.input_to_atoms()
    # handles downloading if remote URL
    |> Waffle.File.new(module)
    |> case do
         {:error, _} = e -> e
         file -> {:ok, file}
       end
  end

  def extract_metadata(path) when is_binary(path) do
    with {:ok, info} <- maybe_get_metadata(path),
         {:ok, stat} <- File.stat(path) do
      {:ok, Map.put(info, :size, stat.size)}
    end
  end

  def extract_metadata(%{path: path}), do: extract_metadata(path)

  defp maybe_get_metadata(path) do
    if(Code.ensure_loaded?(TwinkleStar)) do
      TwinkleStar.from_filepath(path)
    else
      %{}
    end
  end

  def verify_media_type(definition, %{media_type: media_type}) do
    case definition.allowed_media_types() do
      :all -> :ok

      types ->
        if Enum.member?(types, media_type) do
          :ok
        else
          {:error, FileDenied.new(media_type)}
        end
    end
  end

  def blurred(definition \\ nil, media)
  def blurred(definition, %Media{path: path} = _media), do: blurred(definition, path)
  def blurred(_definition, path) when is_binary(path) do

    path = String.trim_leading(path, "/")
    final_path = path<>".jpg"

    ret_path = if String.starts_with?(path, "http") or is_nil(path) or path =="" or not File.exists?(path) do
      debug(path, "it's an external or invalid image, skip")
      path
    else
      if File.exists?(final_path) do
        debug(final_path, "blurred jpeg already exists :)")
        final_path
      else
        debug(final_path, "first time trying to get this blurred jpeg?")
        width = 32
        height = 32
        format = "jpg"

        with %{path: final_path} <- Mogrify.open(path)
          # NOTE: since we're resizing an already resized thumnail, don't worry about cropping, stripping, etc
          |> Mogrify.resize("#{width}x#{height}")
          |> Mogrify.custom("colors", "16")
          |> Mogrify.custom("depth", "8")
          |> Mogrify.custom("blur", "2x2")
          |> Mogrify.quality("50")
          |> Mogrify.format(format)
          # |> IO.inspect
          |> Mogrify.save(path: final_path) do

            debug("saved jpeg")

            final_path
          else e ->
            error(e)
            path
        end
      end
    end

    "/#{ret_path}"
  end

  def data_url(content, mime_type) do
    image_base64 = Base.encode64(content)
    ["data:", mime_type, ";base64,", image_base64]
  end
end
