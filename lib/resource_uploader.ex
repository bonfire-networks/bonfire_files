# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.DocumentUploader do
  @doc """
  Uploader definition for any type of document, allows most media types
  that support documents, archives, video and audio.
  """

  use Bonfire.Files.Definition

  def storage_dir(_, {_file, uploader_id}) when is_binary(uploader_id) do
    "uploads/#{uploader_id}"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get!([__MODULE__, :allowed_media_types])
  end
end
