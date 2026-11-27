# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.EmojiUploader do
  @moduledoc """
  Uploader for custom emoji. An image bigger than `max_size/0` is shrunk to fit it and stripped of its metadata (a GIF or WebP keeps its frames). One that fits is stripped of its metadata without being re-encoded where `gifsicle` (GIF) or `webpmux` (WebP) is available, else it is stored as it is. SVG is sanitised (see `Bonfire.Files.MediaEdit.sanitize_svg/0`).
  """

  use Bonfire.Files.Definition
  use Bonfire.Common.Settings

  alias Bonfire.Common.Utils
  use Bonfire.Common.Config
  import Bonfire.Common.Config, only: [repo: 0]

  alias Bonfire.Files.MediaEdit

  @versions [:default]

  def transform(:default, {%{file_name: filename, path: path}, scope}) do
    size = max_size()

    fits? =
      match?({width, height} when width <= size and height <= size, MediaEdit.dimensions(path))

    cond do
      # an animated PNG is never resized (it would lose its frames): stored as it is, or refused when too big
      apng = MediaEdit.apng_transform(path, size, size) ->
        apng

      # already small: no re-encoding, only the metadata removed where there is a tool for that
      fits? and MediaEdit.image_ext(filename, scope) in ["gif", "webp"] ->
        MediaEdit.strip_metadata(filename, scope)

      fits? and MediaEdit.image_ext(filename, scope) in ["jpg", "jpeg", "png"] ->
        nil

      # shrunk, or (as for the other uploaders) a type that can't be resized, such as SVG
      true ->
        MediaEdit.image(filename, size, size, scope)
    end ||
      :noaction
  end

  def transform(_, _), do: :noaction

  @doc "The width and height (in pixels) an emoji is shrunk to fit within."
  def max_size do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      [__MODULE__, :max_size],
      128
    )
  end

  def prefix_dir() do
    "emoji"
  end

  @impl true
  def allowed_media_types do
    Bonfire.Common.Config.get_ext(
      :bonfire_files,
      # allowed types for this definition
      [__MODULE__, :allowed_media_types],
      # fallback (HEIC, HEIF and AVIF are converted to WebP on upload, see `Bonfire.Files.MediaEdit.heif_to_webp/4`)
      [
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/webp",
        "image/svg+xml",
        "image/apng",
        "image/heic",
        "image/heif",
        "image/avif"
      ]
    )
  end

  @impl true
  def max_file_size do
    Files.normalise_size(
      Bonfire.Common.Config.get([:bonfire_files, :max_user_images_file_size]),
      0.2
    )
  end

  def list(scope_or_opts),
    do: Bonfire.Common.Settings.get(:custom_emoji, nil, scope_or_opts)

  def list_for(:instance), do: Bonfire.Common.Config.get(:custom_emoji, nil)

  def list_for(scope_or_opts),
    do:
      Bonfire.Common.Settings.get(:custom_emoji, nil,
        current_user: Utils.current_user(scope_or_opts),
        one_scope_only: true
      )

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

  # returns the new emoji list, or `{:error, :unauthorized}` when the acting user may not delete the emoji's file
  def delete_emoji_permanently(_id, shortcode, user_or_scope, opts \\ []) do
    emojis = Bonfire.Common.Settings.get(:custom_emoji, %{}, user_or_scope)
    setting = Map.get(emojis, shortcode)
    acting_user = Utils.current_user(opts) || Utils.current_user(user_or_scope)

    # only the file of the scope's own emoji is deleted, whatever id was asked for, and only by its creator or an admin
    result =
      if id = setting && setting[:id] do
        Bonfire.Files.delete_files(__MODULE__, id, current_user: acting_user)
      end

    case result do
      # not allowed: the entry stays, and the caller is told
      {:error, :unauthorized} ->
        {:error, :unauthorized}

      # any other error, such as the media row being gone already: nothing left to protect, so the entry is dropped
      _ ->
        # FIXME: actually remove the entry
        updated_emojis = Map.update(emojis, shortcode, %{}, fn _ -> :deleted end)

        Bonfire.Common.Settings.put(:custom_emoji, updated_emojis, user_or_scope)

        updated_emojis
    end
  end
end
