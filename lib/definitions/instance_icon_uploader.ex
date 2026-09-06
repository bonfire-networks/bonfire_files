# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.InstanceIconUploader do
  @moduledoc """
  Uploader for the instance icon used in navigation, favicons, and social previews.

  Raster uploads are kept large enough for high-density displays without making every avatar use the same larger payload. Vector uploads are stored unchanged and rasterised for consumers that require a bitmap.
  """

  use Bonfire.Files.Definition

  @versions [:default]

  @doc false
  def transform(:default, {%{file_name: "http" <> _ = filename}, _scope}) do
    debug(filename, "do not transform")
    :noaction
  end

  @doc false
  def transform(:default, {%{file_name: filename}, _scope}) do
    Bonfire.Files.MediaEdit.thumbnail(filename, max_size())
    |> debug() ||
      :noaction
  end

  @doc "Returns the maximum width and height of a raster instance icon."
  def max_size do
    Config.get([Bonfire.Files, :max_sizes, :instance_icon, :size], 512,
      name: l("Instance icon max size"),
      description: l("Set a maximum width/height for automatically resizing the instance icon")
    )
  end

  @doc "Returns the storage directory used for instance icons."
  def prefix_dir, do: "instance_icons"

  @impl true
  def allowed_media_types do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      [__MODULE__, :allowed_media_types],
      [
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/svg+xml",
        "image/tiff",
        "image/webp"
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
