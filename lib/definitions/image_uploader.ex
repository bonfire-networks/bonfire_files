# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ImageUploader do
  @moduledoc """
  Uploader for larger images, for example, a profile page banner.

  Does not do any type of image resizing/thumbnailing.
  """

  use Bonfire.Files.Definition

  @versions [:default]

  # def transform(:original, _), do: :noaction

  def transform(:default, _) do
    # TODO: configurable
    max_width = 580
    max_height = 700
    if System.find_executable("convert"), do: {:convert, "-strip -thumbnail #{max_width}x#{max_height}> -limit area 3MB -limit disk 20MB"},
    else: :noaction
  end

  def storage_dir(_, {_file, user_id}) when is_binary(user_id) do
    "data/uploads/#{user_id}/images"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get(
      [__MODULE__, :allowed_media_types], # allowed types for this definition
      ["image/png", "image/jpeg", "image/gif", "image/svg+xml", "image/tiff"] # fallback
    )
  end

end
