# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.VideoUploader do
  @doc """
  Uploader for smaller image icons, usually used as avatars.

  TODO: Support resizing.
  """

  use Bonfire.Files.Definition

  @versions [:default, :thumbnail]

  def transform(:default, {%{file_name: filename}, _scope}) do
    # TODO: do the conversion async (eg. in an Oban queue)
    # if not String.ends_with?(filename, [".mp4", ".webm", ".ogv", ".ogg"]) do 
    #   # ^ just assume these are browser-supported for now
    #   Bonfire.Files.MediaEdit.video_convert(filename) 
    #   # TODO: change mime type of Media to match
    # else 
    :noaction
    # end
  end

  def transform(:thumbnail, {%{file_name: "http" <> _ = filename}, _scope}) do
    debug(filename, "do not extract thumbnail from url")
    :skip
  end

  def transform(:thumbnail, {%{file_name: filename}, _scope}) do
    debug(filename, "transform")

    # TODO: configurable
    scrub_seconds = 10
    scrub_percent = 15
    scrub_frames = nil
    max_size = "#{max_width()}x#{max_height()}"

    Bonfire.Files.MediaEdit.thumbnail_video(filename, max_size,
      seconds: scrub_seconds,
      frames: scrub_frames,
      percent: scrub_percent
    )
    |> debug() ||
      :skip
  end

  # TODO: configurable
  # small timeout, enough only for small videos (need to refactor to convert videos async instead)
  def transform_timeout, do: 30_000
  def max_width, do: 644
  def max_height, do: 362

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
