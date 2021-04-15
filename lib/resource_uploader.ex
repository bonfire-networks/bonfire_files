# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ResourceUploader do
  @doc """
  Uploader definition for any type of resource, allows most media types
  that support documents, archives, video and audio.
  """

  use Bonfire.Files.Definition

  def transform(_file, _scope), do: :noaction

  def storage_dir(_, {file, uploader_id}) when is_binary(uploader_id) do
    "uploads/#{uploader_id}"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get!([__MODULE__, :allowed_media_types])
  end
end
