# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Storage do
  # @type file_source :: Belt.Provider.file_source()
  # @type file_info :: %{info: %Belt.FileInfo{}, media_type: binary, metadata: map}
  # @type file_id :: binary

  # @spec store(upload_def :: any, file :: file_source()) :: {:ok, file_info()} | {:error, term}
  def store(_upload_def, file, opts \\ []) do
    with {:ok, media_type} <- get_media_type(file),
         {:ok, file_info} <- upload_provider() |> Belt.store(file, opts),
         {:ok, metadata} <- get_metadata(file) do
      {:ok,
       %{path: file_info.identifier, info: file_info, media_type: media_type, metadata: metadata}}
    end
  end

  # @spec remote_url(file_id()) :: {:ok, binary} | {:error, term}
  def remote_url(file_id) do
    # IO.inspect(file_id: file_id)

    with {:ok, url} <- upload_provider() |> Belt.get_url(file_id) do
      # IO.inspect(url: url)
      {:ok, URI.encode(url)}
    end
  end

  # @spec delete(file_id()) :: :ok | {:error, term}
  def delete(file_id) do
    upload_provider() |> Belt.delete(file_id)
  end

  # @spec delete_all() :: :ok | {:error, term}
  def delete_all do
    upload_provider() |> Belt.delete_all()
  end

  defp upload_provider do
    {:ok, provider} =
      :commons_pub
      |> Application.fetch_env!(Bonfire.Files)
      |> Belt.Provider.Filesystem.new()

    provider
  end

  defp get_media_type(%{path: path}) do
    with {:ok, info} <- TwinkleStar.from_filepath(path) do
      {:ok, info.media_type}
    end
  end

  defp get_metadata(%{path: _path}) do
    # TODO
    {:ok, %{}}
  end
end
