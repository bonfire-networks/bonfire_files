# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.EmojiUploader do
  @doc """
  Uploader for smaller image icons, usually used as avatars.

  TODO: Support resizing.
  """

  use Bonfire.Files.Definition
  use Bonfire.Common.Settings

  alias Bonfire.Common.Utils
  use Bonfire.Common.Config
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
    # IO.inspect(media, label: "mediaaaa")
    setting = prepare_setting(media)
    put_setting(metadata, setting, opts)
  end

  def prepare_setting(%{id: media_id, metadata: metadata} = media) do
    # IO.inspect(url, label: "urlll")
    %{id: media_id, label: metadata[:label], url: permanent_url(media)}
  end

  # def prepare_setting(%{id: media_id, metadata: metadata, file: %{} = file}) do
  #   # IO.inspect(file, label: "fileee")
  #   %{id: media_id, label: metadata[:label], file: file}
  # end

  def put_setting(metadata, setting, opts) do
    Bonfire.Common.Settings.put(
      [:custom_emoji, metadata.shortcode],
      setting,
      opts
    )
  end

  def archive_emoji(id, shortcode, user_or_scope) do
    setting = Bonfire.Common.Settings.get([:custom_emoji, shortcode], nil, user_or_scope)

    if setting do
      updated = Map.put(setting, :archived, true)
      Bonfire.Common.Settings.put([:custom_emoji, shortcode], updated, user_or_scope)
    end
  end

  # returns new emoji list
  def delete_emoji_permanently(id, shortcode, user_or_scope) do
    emojis = Bonfire.Common.Settings.get(:custom_emoji, %{}, user_or_scope)
    setting = Map.get(emojis, shortcode)

    if id = id || (setting && setting[:id]) do
      Bonfire.Files.delete_files(__MODULE__, id, user_or_scope)
    end

    # FIXME: actually remove the entry
    updated_emojis = Map.update(emojis, shortcode, %{}, fn _ -> :deleted end)

    Bonfire.Common.Settings.put(:custom_emoji, updated_emojis, user_or_scope)

    updated_emojis
  end
end
