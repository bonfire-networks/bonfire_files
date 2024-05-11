# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.VideoUploader do
  @doc """
  Uploader for smaller image icons, usually used as avatars.

  TODO: Support resizing.
  """

  use Bonfire.Files.Definition

  @versions [:default, :thumbnail]

  def transform(:default, _), do: :noaction

  def transform(:thumbnail, {%{file_name: "http" <> _ = filename}, _scope}) do
    debug(filename, "do not extract thumbnail from url")
    :skip
  end

  def transform(:thumbnail, {%{file_name: filename}, _scope}) do
    debug(filename, "transform")

    # TODO: configurable
    scrub_frames = 10 * 26
    max_size = Bonfire.Files.ImageUploader.max_width()

    Bonfire.Files.Image.Edit.thumbnail_video(filename, scrub_frames, max_size)
    |> debug() ||
      :skip
  end

  def prefix_dir() do
    "videos"
  end

  def allowed_media_types do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      # allowed types for this definition
      [__MODULE__, :allowed_media_types],
      # fallback 
      [
        "video/mp4",
        "video/mpeg",
        "video/ogg",
        "video/webm"
      ]
    )
  end

  def max_file_size do
    Files.normalise_size(
      Bonfire.Common.Config.get([:bonfire_files, :max_user_video_file_size]),
      20
    )
  end
end
