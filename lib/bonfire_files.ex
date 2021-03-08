# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files do
  alias Ecto.Changeset
  alias Bonfire.Repo
  alias Bonfire.Data.Identity.User

  alias Bonfire.Files.{
    Content,
    FileDenied,
    Storage,
    Queries
  }

  def one(filters), do: Repo.single(Queries.query(Content, filters))

  def many(filters \\ []), do: {:ok, Repo.all(Queries.query(Content, filters))}

  @doc """
  Attempt to store a file, returning an upload, for any parent item that
  participates in the meta abstraction, providing the actor responsible for
  the upload.
  """
  @spec upload(upload_def :: any, uploader :: User.t(), file :: any, attrs :: map) ::
          {:ok, Content.t()} | {:error, Changeset.t()}
  def upload(upload_def, uploader, file, attrs) do
    file = Bonfire.Common.Utils.input_to_atoms(file)
    # IO.inspect(upload: file)

    with {:ok, file} <- parse_file(file),
         {:ok, content} <- insert_content(upload_def, uploader, file, attrs),
         {:ok, url} <- remote_url(content) do
      {:ok, %{content | url: url}}
    end
  end

  defp insert_content(upload_def, uploader, %{} = file, attrs) do
    attrs = Map.merge(file, attrs)

    with {:ok, file_info} <- upload_def.store({file, uploader.id}) do
      attrs =
        attrs
        |> Map.put(:path, file_info.path)
        |> Map.put(:size, file_info.info.size)

      with {:ok, content} <- Repo.insert(Content.changeset(uploader, attrs)) do
        {:ok, content}
      else
        e ->
          # rollback file changes on failure
          upload_def.delete(file_info.path)
          e
      end
    end
  end

  defp insert_content(_, _, nil, attrs) do
    attrs
  end

  @doc """
  Attempt to fetch a remotely accessible URL for the associated file in an upload.
  """
  def remote_url(%Content{path: path}), do: Storage.remote_url(path)

  def remote_url_from_id(content_id) when is_binary(content_id) do
    case __MODULE__.one(id: content_id) do
      {:ok, content} ->
        {:ok, url} = remote_url(content)
        url

      _ ->
        nil
    end
  end

  def remote_url_from_id(_), do: nil

  def update_by(filters, updates) do
    Repo.update_all(Queries.query(Content, filters), set: updates)
  end

  @doc """
  Delete an upload, removing it from indexing, but the files remain available.
  """
  @spec soft_delete(Content.t()) :: {:ok, Content.t()} | {:error, Changeset.t()}
  def soft_delete(%Content{} = content) do
    Bonfire.Repo.Delete.soft_delete(content)
  end

  # def soft_delete_by(filters) do

  # end

  @doc """
  Delete an upload, removing any associated files.
  """
  @spec hard_delete(Content.t()) :: :ok | {:error, Changeset.t()}
  def hard_delete(%Content{} = content) do
    resp =
      Repo.transaction(fn ->
        with {:ok, content} <- Repo.delete(content),
             {:ok, _} <- Storage.delete(content.content_upload.path) do
          :ok
        end
      end)

    with {:ok, v} <- resp, do: v
  end

  # Sweep deleted content
  @doc false
  def hard_delete() do
    delete_by(deleted: true)
  end

  defp delete_by(filters) do
    Queries.query(Content)
    |> Queries.filter(filters)
    |> Repo.delete_all()
  end

  defp is_remote_file?(%{url: url}), do: is_remote_file?(url)

  defp is_remote_file?(url) when is_binary(url) do
    uri = URI.parse(url)
    not is_nil(uri.host)
  end

  defp is_remote_file?(_other), do: false

  defp parse_file(%{url: url, upload: upload})
       when is_binary(url) and url != "" and not is_nil(upload) do
    {:error, :both_url_and_upload_should_not_be_set}
  end

  if Mix.env() == :test do
    # FIXME: seriously don't do this, send help
    defp parse_file(%{url: url} = file) when is_binary(url) do
      {:ok, file_info} = CommonsPub.MockFileParser.from_uri(url)
      {:ok, Map.merge(file, file_info)}
    end
  else
    defp parse_file(%{url: url} = file) when is_binary(url) and url != "" do
      with {:ok, file_info} <- TwinkleStar.from_uri(url, follow_redirect: true) do
        {:ok, Map.merge(file, file_info)}
      else
        # match behaviour of uploads
        {:error, {:request_failed, 404}} -> {:error, :enoent}
        {:error, {:request_failed, 403}} -> {:error, :forbidden}
        {:error, :bad_request} -> {:error, :bad_request}
        {:error, {:tls_alert, _}} -> {:error, :tls_alert}
        {:error, other} -> {:error, other}
      end
    end
  end

  defp parse_file(%{upload: %{path: path} = file}) do
    with {:ok, file_info} <- TwinkleStar.from_filepath(path) do
      file =
        file
        |> Map.take([:path, :filename])
        |> Map.merge(file_info)

      {:ok, file}
    end
  end

  # defp parse_file(_), do: {:error, :missing_url_or_upload}
  defp parse_file(_), do: {:ok, nil}

  def base_url() do
    Bonfire.Common.Config.get([__MODULE__, :base_url])
  end

  def prepend_url(url) do
    base_url()
    |> URI.merge(url)
    |> URI.to_string()
  end
end
