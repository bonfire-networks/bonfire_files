# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ImageUploader do
  @moduledoc """
  Uploader for larger images, for example, a profile page banner.

  Does not do any type of image resizing/thumbnailing.
  """

  use Bonfire.Files.Definition

  def storage_dir(_, {file, user_id}) when is_binary(user_id) do
    "data/uploads/#{user_id}/images"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get([__MODULE__, :allowed_media_types], ["image/png", "image/jpeg", "image/gif", "image/svg+xml", "image/tiff"])
  end

  def upload(user, file, attrs \\ %{}) do
    Bonfire.Files.upload(__MODULE__, user, file, attrs)
  end

end
