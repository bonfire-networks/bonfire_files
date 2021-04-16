# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.IconUploader do
  @doc """
  User for smaller image icons, usually used as avatars.

  TODO: Support resizing.
  """

  use Bonfire.Files.Definition

  def storage_dir(_, {_file, user_id}) when is_binary(user_id) do
    "uploads/#{user_id}/icons"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get!([__MODULE__, :allowed_media_types])
  end
end
