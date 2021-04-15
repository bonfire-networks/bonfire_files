# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files do
  alias Ecto.Changeset
  alias Bonfire.Repo
  alias Bonfire.Data.Identity.User

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
  @spec upload(upload_def :: any, uploader :: User.t(), file :: any, attrs :: map) ::
          {:ok, Media.t()} | {:error, Changeset.t()}
  def upload(upload_def, uploader, file, attrs \\ %{}) do
    with {:ok, file} <- fetch_file(upload_def, file),
         {:ok, file_info} <- extract_metadata(file),
         {:ok, new_path} <- upload_def.store({file.path, uploader.id}) do
      insert_content(uploader, %{file | path: new_path}, file_info, attrs)
    else
      e ->
        # rollback file changes on failure
        upload_def.delete(file.path)
      e
    end
  end

  defp insert_content(uploader, file, file_info, attrs) do
    attrs =
      attrs
      |> Map.put(:path, file.path)
      |> Map.put(:size, file_info.size)
      |> Map.put(:media_type, file_info.media_type)

    Repo.insert(Media.changeset(uploader, attrs))
  end

  @doc """
  Attempt to fetch a remotely accessible URL for the associated file in an upload.
  """
  def remote_url(upload_def, %Media{} = content),
    do: upload_def.url({content.path, content.uploader_id})

  def remote_url_from_id(upload_def, content_id) when is_binary(content_id) do
    case __MODULE__.one(id: content_id) do
      {:ok, content} ->
        {:ok, url} = remote_url(upload_def, content)
        url

      _ ->
        nil
    end
  end

  def remote_url_from_id(_, _), do: nil

  def update_by(filters, updates) do
    Repo.update_all(Queries.query(Media, filters), set: updates)
  end

  @doc """
  Delete an upload, removing it from indexing, but the files remain available.
  """
  @spec soft_delete(Media.t()) :: {:ok, Media.t()} | {:error, Changeset.t()}
  def soft_delete(%Media{} = content) do
    Bonfire.Repo.Delete.soft_delete(content)
  end

  @doc """
  Delete an upload, removing any associated files.
  """
  @spec hard_delete(atom, Media.t()) :: :ok | {:error, Changeset.t()}
  def hard_delete(upload_def, %Media{} = content) do
    resp =
      Repo.transaction(fn ->
        with {:ok, content} <- Repo.delete(content),
             {:ok, _} <- upload_def.delete({content.path, content.uploader_id}) do
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
    TwinkleStar.from_filepath(path)
  end

  defp extract_metadata(%{path: path}), do: extract_metadata(path)
end
