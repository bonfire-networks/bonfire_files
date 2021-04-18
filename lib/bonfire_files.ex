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

  alias Ecto.Changeset
  alias Bonfire.Repo

  alias Bonfire.Files.{
    Media,
    FileDenied,
    Queries
  }

  def one(filters), do: Repo.single(Queries.query(Media, filters))

  def many(filters \\ []), do: {:ok, Repo.all(Queries.query(Media, filters))}

  @doc """
  Attempt to store a file, returning an upload, for any parent item that
  participates in the meta abstraction, providing the actor responsible for
  the upload.
  """
  def upload(upload_def, user, file, attrs \\ %{}) do
    with {:ok, file} <- fetch_file(upload_def, file),
         {:ok, file_info} <- extract_metadata(file),
         :ok <- verify_media_type(upload_def, file_info),
         {:ok, new_path} <- upload_def.store({file.path, user.id}) do
      insert_media(user, %{file | path: new_path}, file_info, attrs)
    end
  end

  defp insert_media(user, file, file_info, attrs) do
    attrs =
      attrs
      |> Map.put(:path, file.path)
      |> Map.put(:size, file_info.size)
      |> Map.put(:media_type, file_info.media_type)

    Repo.insert(Media.changeset(user, attrs))
  end

  @doc """
  Return the URL that a local file has.
  """
  @spec remote_url(atom, Media.t()) :: binary
  def remote_url(upload_def, %Media{} = media),
    do: upload_def.url({media.path, media.user_id})

  def remote_url(upload_def, media_id) when is_binary(media_id) do
    case __MODULE__.one(id: media_id) do
      {:ok, media} ->
        remote_url(upload_def, media)

      _ ->
        nil
    end
  end

  def remote_url(_, _), do: nil

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
  def hard_delete(upload_def, %Media{} = media) do
    resp =
      Repo.transaction(fn ->
        with {:ok, media} <- Repo.delete(media),
             {:ok, _} <- upload_def.delete({media.path, media.user_id}) do
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

  defp fetch_file(upload_def, file) do
    file
    |> Bonfire.Common.Utils.input_to_atoms()
    # handles downloading if remote
    |> Waffle.File.new(upload_def)
    |> case do
         {:error, _} = e -> e
         file -> {:ok, file}
       end
  end

  defp extract_metadata(path) when is_binary(path) do
    with {:ok, info} <- TwinkleStar.from_filepath(path),
         {:ok, stat} <- File.stat(path) do
      {:ok, Map.put(info, :size, stat.size)}
    end
  end

  defp extract_metadata(%{path: path}), do: extract_metadata(path)

  defp verify_media_type(upload_def, %{media_type: media_type}) do
    case upload_def.allowed_media_types() do
      :all -> :ok

      types ->
        if Enum.member?(types, media_type) do
          :ok
        else
          {:error, FileDenied.new(media_type)}
        end
    end
  end
end
