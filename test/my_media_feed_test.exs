# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.MyMediaFeedTest do
  @moduledoc """
  The `my_media` feed: a person's own media that an activity reaches (attached to something they published, or published on its own), one row per `Media`, as a media picker lists it. With `sort_by: :last_used`, the media used most recently comes first, whatever its upload date.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  import Bonfire.Social.Fake, only: [upload_media: 3, post_with_media: 3]

  alias Bonfire.Social.FeedLoader

  setup do
    {:ok, me: fake_user!(), other: fake_user!()}
  end

  defp my_media(me, filters \\ %{}, opts \\ []) do
    FeedLoader.feed(:my_media, filters, [current_user: me, by: me, paginate?: true] ++ opts)
  end

  defp media_ids(%{edges: edges}), do: Enum.map(edges, &Enums.id/1)

  test "lists only my media, one row each", %{me: me, other: other} do
    mine = upload_media(:images, me, "mine")
    post_with_media(me, mine, "mine")
    # the same file used again: still one row
    post_with_media(me, mine, "mine again")

    theirs = upload_media(:images, other, "theirs")
    post_with_media(other, theirs, "theirs")

    assert media_ids(my_media(me)) == [mine.id]
  end

  # a DM's media stays out of the picker unless asked for, since placing it in a wider post would make it as public as that post
  test "leaves out media I only sent in a direct message", %{me: me, other: other} do
    in_dm = upload_media(:images, me, "in a DM")

    {:ok, _message} =
      Bonfire.Messages.send(
        me,
        %{post_content: %{html_body: "a picture for you"}, uploaded_media: [in_dm]},
        [other.id]
      )

    # the control: the same kind of media in a post is listed
    in_post = upload_media(:images, me, "in a post")
    post_with_media(me, in_post, "in a post")

    listed = media_ids(my_media(me))
    assert in_post.id in listed
    refute in_dm.id in listed
  end

  test "with `sort_by: :last_used`, the media used most recently comes first, and pages don't repeat",
       %{me: me} do
    older = upload_media(:images, me, "older upload")
    newer = upload_media(:images, me, "newer upload")
    post_with_media(me, older, "1")
    post_with_media(me, newer, "2")

    # the control: by default, newest upload first
    assert media_ids(my_media(me)) == [newer.id, older.id]

    # the older upload is used again, so it was used last
    post_with_media(me, older, "3")

    assert media_ids(my_media(me, %{sort_by: :last_used})) == [older.id, newer.id]

    first = my_media(me, %{sort_by: :last_used}, limit: 1)
    assert media_ids(first) == [older.id]

    second =
      my_media(me, %{sort_by: :last_used},
        limit: 1,
        after: first.page_info.end_cursor
      )

    assert media_ids(second) == [newer.id]
  end
end
