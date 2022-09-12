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
    if not String.ends_with?(filename, ".gif") do
      Bonfire.Files.Image.Edit.image(
        filename,
        Bonfire.Common.Config.get_ext(
          :bonfire_files,
          [__MODULE__, :max_width],
          580
        ),
        Bonfire.Common.Config.get_ext(
          :bonfire_files,
          [__MODULE__, :max_height],
          700
        )
      )
    end ||
      :noaction
  end

  def storage_dir(_, {_file, user_id}) when is_binary(user_id) do
    "data/uploads/#{user_id}/images"
  end

  def allowed_media_types do
    # allowed types for this definition
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      [__MODULE__, :allowed_media_types],
      # fallback
      ["image/png", "image/jpeg", "image/gif", "image/svg+xml", "image/tiff"]
    )
  end
end
