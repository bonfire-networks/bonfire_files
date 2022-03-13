# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.DocumentUploader do
  @doc """
  Definition for any type of document, allows most media types
  that support documents, archives, video and audio.
  """

  use Bonfire.Files.Definition

  def storage_dir(_, {_file, user_id}) when is_binary(user_id) do
    "data/uploads/#{user_id}/docs"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get!([__MODULE__, :allowed_media_types])
  end

end
