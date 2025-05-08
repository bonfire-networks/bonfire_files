# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.IconUploader do
  @doc """
  Uploader for smaller image icons, usually used as avatars.

  TODO: Support resizing.
  """

  use Bonfire.Files.Definition

  @versions [:default]

  # def transform(:original, _), do: :noaction

  def transform(:default, {%{file_name: "http" <> _ = filename}, _scope}) do
    debug(filename, "do not transform")
    :noaction
  end

  def transform(:default, {%{file_name: filename}, _scope}) do
    debug(filename, "transform")

    max_size =
      Config.get([Bonfire.Files, :max_sizes, :banner, :height], 142,
        name: l("Icon/avatar max size"),
        description:
          l("Set a maximum width/height for automatically resizing avatar or icon images")
      )

    Bonfire.Files.MediaEdit.thumbnail(filename, max_size)
    |> debug() ||
      :noaction
  end

  # def transform(:small, _) do
  #   max_size = 48
  #   {:convert, "-strip -thumbnail #{max_size}x#{max_size} -gravity center -crop #{max_size}x#{max_size}+0+0 -limit area 50MB -limit disk 2MB"}
  # end

  def prefix_dir() do
    "icons"
  end

  @impl true
  def allowed_media_types do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      # allowed types for this definition
      [__MODULE__, :allowed_media_types],
      # fallback
      ["image/png", "image/jpeg", "image/gif", "image/tiff", "image/webp"]
    )
  end

  @impl true
  def max_file_size do
    Files.normalise_size(
      Bonfire.Common.Config.get([:bonfire_files, :max_user_images_file_size]),
      6
    )
  end
end
