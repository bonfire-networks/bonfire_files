# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ImageUploader do
  @moduledoc """
  Uploader for larger images, for example, a profile page banner.

  Does not do any type of image resizing/thumbnailing.
  """

  use Bonfire.Files.Definition

  @versions [:default]

  # def transform(:original, _), do: :noaction

  def transform(:default, {%{file_name: "http" <> _ = filename}, _scope}) do
    debug(filename, "do not transform")
    :noaction
  end

  # a GIF is not resized (it would lose its frames), only stripped of its metadata where `gifsicle` is available
  # an animated PNG is not resized either: stored as it is, or refused when bigger than the box
  def transform(:default, {%{file_name: filename, path: path}, scope}) do
    if Bonfire.Files.MediaEdit.image_ext(filename, scope) == "gif" do
      Bonfire.Files.MediaEdit.strip_metadata(filename, scope)
    else
      Bonfire.Files.MediaEdit.apng_transform(path, max_width(), max_height()) ||
        Bonfire.Files.MediaEdit.image(
          filename,
          max_width(),
          max_height(),
          scope
        )
    end ||
      :noaction
  end

  def max_width do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      [__MODULE__, :max_width],
      580
    )
  end

  def max_height do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      [__MODULE__, :max_height],
      700
    )
  end

  def prefix_dir() do
    "images"
  end

  @impl true
  def allowed_media_types do
    # allowed types for this definition
    # HEIC, HEIF and AVIF are converted to WebP on upload (see `Bonfire.Files.MediaEdit.heif_to_webp/4`)
    # TODO: JPEG XL could be accepted the same way once the security of its loader is sorted (libvips marks `jxlload` as untrusted)
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      [__MODULE__, :allowed_media_types],
      # fallback
      [
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/svg+xml",
        "image/tiff",
        "image/heic",
        "image/heif",
        "image/avif"
      ]
    )
  end

  @impl true
  def max_file_size do
    Files.normalise_size(
      Bonfire.Common.Config.get([:bonfire_files, :max_user_images_file_size]),
      5
    )
  end
end
