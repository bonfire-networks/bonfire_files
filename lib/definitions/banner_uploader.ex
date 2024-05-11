# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.BannerUploader do
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

  def transform(:default, {%{file_name: filename}, _scope}) do
    Bonfire.Files.MediaEdit.banner(filename, max_width(), max_height()) ||
      :noaction
  end

  # TODO: configurable
  def max_width, do: 580
  def max_height, do: 200

  def prefix_dir() do
    "banners"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      # allowed types for this definition
      [__MODULE__, :allowed_media_types],
      # fallback
      ["image/png", "image/jpeg", "image/gif", "image/svg+xml", "image/tiff"]
    )
  end

  def max_file_size do
    Files.normalise_size(
      Bonfire.Common.Config.get([:bonfire_files, :max_user_images_file_size]),
      8
    )
  end
end
