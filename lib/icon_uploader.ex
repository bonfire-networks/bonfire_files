# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.IconUploader do
  @doc """
  Uploader for smaller image icons, usually used as avatars.

  TODO: Support resizing.
  """

  use Waffle.Definition

  def validate({file, _}) do
    with {:ok, file_info} <- TwinkleStar.from_filepath(file.path) do
      Enum.member?(extension_whitelist(), file_info.media_type)
    end
  end

  def transform(_file), do: :skip

  def storage_dir(_, {file, uploader_id}) when is_binary(uploader_id) do
    "uploads/#{uploader_id}/icons"
  end

  def extension_whitelist do
    Bonfire.Common.Config.get!([__MODULE__, :allowed_media_types])
  end
end
