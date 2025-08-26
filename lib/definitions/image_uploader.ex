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

  def transform(:default, {%{file_name: filename}, _scope}) do
    if not String.ends_with?(filename, ".gif") do
      Bonfire.Files.MediaEdit.image(
        filename,
        max_width(),
        Bonfire.Common.Config.get_ext(
          :bonfire_files,
          [__MODULE__, :max_height],
          700
        )
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

  def prefix_dir() do
    "images"
  end

  @impl true
  def allowed_media_types do
    # allowed types for this definition
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      [__MODULE__, :allowed_media_types],
      # fallback
      ["image/png", "image/jpeg", "image/gif", "image/svg+xml", "image/tiff"]
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
