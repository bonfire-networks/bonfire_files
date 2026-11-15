# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.EmojiDeleteGuestTest do
  @moduledoc """
  A visitor with no session and no live socket reaches any LiveView or component's `handle_event/3` through `GET /LiveHandler/<Module>/<event>`, so deleting a custom emoji must never delete a file that belongs to someone else.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  import Phoenix.ConnTest
  @endpoint Application.compile_env!(:bonfire, :endpoint_module)

  import Bonfire.Files.Simulation

  alias Bonfire.Files
  alias Bonfire.Files.EmojiUploader
  alias Bonfire.Files.Media

  test "a guest cannot delete another user's uploaded file with delete_emoji_permanently" do
    owner = fake_user!()
    assert {:ok, media} = Files.upload(EmojiUploader, owner, icon_file(), %{})

    path = Files.local_path(media)
    assert {:ok, _} = Media.one(id: media.id)
    assert is_binary(path) and File.exists?(path)

    # the handler assigns on the conn after deleting, which raises; the outcome is checked either way
    try do
      get(
        build_conn(),
        "/LiveHandler/Bonfire.Files.Web.UploadEmojiLive/delete_emoji_permanently?id=#{media.id}&shortcode=:victim:"
      )
    rescue
      ArgumentError -> :ok
    end

    assert {:ok, _} = Media.one(id: media.id)
    assert File.exists?(path)
  end

  defp socket_for(user) do
    socket = %Phoenix.LiveView.Socket{
      endpoint: @endpoint,
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}},
      assigns: %{
        __changed__: %{},
        flash: %{},
        __context__: %{current_user_id: user.id, current_user: user},
        current_user_id: user.id,
        current_user: user
      }
    }

    socket
  end

  defp upload_emoji(owner, shortcode) do
    metadata = EmojiUploader.prepare_meta("Mine", shortcode)
    assert {:ok, media} = Files.upload(EmojiUploader, owner, icon_file(), %{metadata: metadata})
    EmojiUploader.media_put_setting(media, metadata, current_user: owner)
    media
  end

  defp delete_event(user, media_id, shortcode) do
    Bonfire.Files.Web.UploadEmojiLive.handle_event(
      "delete_emoji_permanently",
      %{"id" => media_id, "shortcode" => shortcode},
      socket_for(user)
    )
  end

  test "a signed-in user cannot delete another user's uploaded file with delete_emoji_permanently" do
    owner = fake_user!()
    stranger = fake_user!()
    assert {:ok, media} = Files.upload(EmojiUploader, owner, icon_file(), %{})
    path = Files.local_path(media)
    assert is_binary(path) and File.exists?(path)

    assert {:noreply, _} = delete_event(stranger, media.id, ":victim:")

    assert {:ok, _} = Media.one(id: media.id)
    assert File.exists?(path)
  end

  test "a signed-in user cannot delete another user's emoji by naming its shortcode" do
    owner = fake_user!()
    stranger = fake_user!()
    media = upload_emoji(owner, ":mine:")
    path = Files.local_path(media)
    assert is_binary(path) and File.exists?(path)

    # the stranger's own scope has no such emoji, so the id they name isn't theirs to delete
    assert {:noreply, _} = delete_event(stranger, media.id, ":mine:")

    assert {:ok, _} = Media.one(id: media.id)
    assert File.exists?(path)
  end

  test "a user can delete their own emoji with delete_emoji_permanently" do
    owner = fake_user!()
    media = upload_emoji(owner, ":mine:")
    path = Files.local_path(media)
    assert is_binary(path) and File.exists?(path)

    # as a LiveView has it: the user loaded afresh, so with the emoji setting just stored
    owner = Bonfire.Me.Users.get_current(owner.id)
    assert {:noreply, _} = delete_event(owner, media.id, ":mine:")

    refute File.exists?(path)
  end

  test "deleting an emoji whose media row is already gone drops its entry" do
    owner = fake_user!()
    media = upload_emoji(owner, ":gone:")
    assert {:ok, _} = Media.hard_delete(nil, media, current_user: owner)
    assert {:error, :not_found} = Media.one(id: media.id)

    owner = Bonfire.Me.Users.get_current(owner.id)
    assert %{id: _} = Bonfire.Common.Settings.get([:custom_emoji, ":gone:"], nil, owner)

    assert %{} =
             EmojiUploader.delete_emoji_permanently(media.id, ":gone:", owner,
               current_user: owner
             )

    owner = Bonfire.Me.Users.get_current(owner.id)
    assert Bonfire.Common.Settings.get([:custom_emoji, ":gone:"], nil, owner) == :deleted
  end

  test "deleting an emoji the acting user may not delete keeps its entry and says so" do
    owner = fake_user!()
    stranger = fake_user!()
    media = upload_emoji(owner, ":kept:")
    path = Files.local_path(media)
    owner = Bonfire.Me.Users.get_current(owner.id)

    assert {:error, :unauthorized} =
             EmojiUploader.delete_emoji_permanently(media.id, ":kept:", owner,
               current_user: stranger
             )

    assert File.exists?(path)
    owner = Bonfire.Me.Users.get_current(owner.id)
    assert %{id: _} = Bonfire.Common.Settings.get([:custom_emoji, ":kept:"], nil, owner)
  end

  defp count(schema), do: Bonfire.Common.Config.repo().aggregate(schema, :count)

  test "a guest cannot add a custom emoji with upload" do
    owner = fake_user!()

    # the counts only mean something if an emoji upload does add rows
    media_before = count(Media)
    assert {:ok, _media} = Files.upload(EmojiUploader, owner, icon_file(), %{})
    assert count(Media) > media_before

    {media_before, emoji_before} = {count(Media), count(Bonfire.Data.Social.Emoji)}

    # the handler assigns on the conn after failing, which raises; the outcome is checked either way
    try do
      get(
        build_conn(),
        "/LiveHandler/Bonfire.Files.Web.UploadEmojiLive/upload?label=Evil&shortcode=:evil:"
      )
    rescue
      ArgumentError -> :ok
    end

    assert count(Media) == media_before
    assert count(Bonfire.Data.Social.Emoji) == emoji_before
  end
end
