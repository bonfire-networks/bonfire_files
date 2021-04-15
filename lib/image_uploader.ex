# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ImageUploader do
  use Waffle.Definition

  @doc """
  Uploader for larger images, for example, a profile page banner.

  Does not do any type of image resizing/thumbnailing.
  """

  def transform(_file, _scope), do: :skip

  def storage_dir(_, {file, uploader_id}) when is_binary(uploader_id) do
    "uploads/#{uploader_id}/images"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get!([__MODULE__, :allowed_media_types])
  end
end
