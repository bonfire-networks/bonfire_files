# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.EmojiUploader do
  @doc """
  Uploader for smaller image icons, usually used as avatars.

  TODO: Support resizing.
  """

  use Bonfire.Files.Definition
  alias Bonfire.Common.Utils
  import Bonfire.Common.Config, only: [repo: 0]

  @versions [:default]

  def transform(_, _), do: :noaction

  def prefix_dir() do
    "emoji"
  end

  @impl true
  def allowed_media_types do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      # allowed types for this definition
      [__MODULE__, :allowed_media_types],
      # fallback
      ["image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml", "image/apng"]
    )
  end

  @impl true
  def max_file_size do
    Files.normalise_size(
      Bonfire.Common.Config.get([:bonfire_files, :max_user_images_file_size]),
      0.2
    )
  end

  def list(:instance), do: Bonfire.Common.Config.get(:custom_emoji, nil)

  def list(scope),
    do: Bonfire.Common.Settings.get(:custom_emoji, nil, current_user: Utils.current_user(scope))

  def add_emoji(user, file, label, shortcode) do
    metadata = prepare_meta(label, shortcode)

    {:ok, emoji} = Bonfire.Data.Social.Emoji.changeset(%{}) |> repo().insert()

    {:ok, upload} =
      Bonfire.Files.upload(__MODULE__, {user, emoji}, file, %{metadata: metadata})

    media_put_setting(upload, metadata, current_user: user)
  end

  def prepare_meta(label, shortcode) do
    shortcode = ":#{String.trim(shortcode, ":")}:"

    %{
      media_type: "emoji",
      label: label,
      shortcode: shortcode
    }
  end

  def media_put_setting(media, metadata, opts) do
    setting = prepare_setting(media)
    put_setting(metadata, setting, opts)
  end

  def prepare_setting(%{id: media_id, path: url, metadata: metadata}) do
    %{id: media_id, label: metadata[:label], url: url}
  end

  def put_setting(metadata, setting, opts) do
    Bonfire.Common.Settings.put(
      [:custom_emoji, metadata.shortcode],
      setting,
      opts
    )
  end
end
