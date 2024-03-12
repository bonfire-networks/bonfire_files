# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.EmojiUploader do
  @doc """
  Uploader for smaller image icons, usually used as avatars.

  TODO: Support resizing.
  """

  use Bonfire.Files.Definition

  @versions [:default]

  def transform(_, _), do: :noaction

  def prefix_dir() do
    "emoji"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      # allowed types for this definition
      [__MODULE__, :allowed_media_types],
      # fallback
      ["image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml", "image/apng"]
    )
  end

  def max_file_size do
    Files.normalise_size(
      Bonfire.Common.Config.get([:bonfire_files, :max_user_images_file_size]),
      0.2
    )
  end
end
