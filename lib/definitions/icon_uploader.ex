# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.IconUploader do
  @doc """
  Uploader for smaller image icons, usually used as avatars.

  TODO: Support resizing.
  """

  use Bonfire.Files.Definition

  def storage_dir(_, {_file, user_id}) when is_binary(user_id) do
    "data/uploads/#{user_id}/icons"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get([__MODULE__, :allowed_media_types], ["image/png", "image/jpeg", "image/gif"])
  end

  def upload(user, file, attrs \\ %{}) do
    Bonfire.Files.upload(__MODULE__, user, file, attrs)
  end

  def remote_url(media), do: Bonfire.Files.remote_url(__MODULE__, media)

end
