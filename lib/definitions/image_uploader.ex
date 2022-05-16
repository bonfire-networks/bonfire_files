# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ImageUploader do
  @moduledoc """
  Uploader for larger images, for example, a profile page banner.

  Does not do any type of image resizing/thumbnailing.
  """

  use Bonfire.Files.Definition

  @versions [:default]

  # def transform(:original, _), do: :noaction

  def transform(:default, {%{file_name: filename}, _scope}) do
    Bonfire.Files.Image.Edit.banner(filename) || :noaction
  end

  def storage_dir(_, {_file, user_id}) when is_binary(user_id) do
    "data/uploads/#{user_id}/images"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get_ext(:bonfire_files,
      [__MODULE__, :allowed_media_types], # allowed types for this definition
      ["image/png", "image/jpeg", "image/gif", "image/svg+xml", "image/tiff"] # fallback
    )
  end

end
