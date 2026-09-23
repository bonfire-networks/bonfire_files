defmodule Bonfire.Files.FeedFiltersTest do
  @moduledoc """
  A feed can be narrowed by the media its activities carry, by type, and by whether there is any at all.

  Characterised here before the filters moved out of `bonfire_social`: media are this extension's, so the query that reads them belongs here too, and these tests are what says the move changed nothing. A media type matches by prefix, so `image` covers `image/png`, and `*` means any media.

  The two directions give different kinds of feed, which the probes follow. Asking *for* a media type gives a feed of the media themselves, which is what the images and videos feeds are, so those tests look for media by id. Leaving a type *out* keeps a feed of activities, so those look for posts.
  """
  use Bonfire.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Me.Fake
  import Bonfire.Posts.Fake

  setup do
    # three fixtures, and tests paginate at 2 by default
    Process.put([:bonfire, :default_pagination_limit], 10)

    me = Fake.fake_user!()
    other = Fake.fake_user!()

    {image, with_image} = Bonfire.Social.Fake.create_test_content(:image_post, me, other)
    {video, with_video} = Bonfire.Social.Fake.create_test_content(:video_post, me, other)
    plain = fake_post!(me, "public", %{post_content: %{html_body: "no media here"}})

    {:ok,
     me: me,
     image: image,
     video: video,
     with_image: with_image,
     with_video: with_video,
     plain: plain}
  end

  # a filter that admits all three, since a custom feed with no filter at all resolves to no feed
  defp posts(me, filters),
    do: FeedLoader.feed(:custom, Map.merge(%{object_types: [:post]}, filters), current_user: me)

  defp contains?(feed, me, post), do: FeedLoader.feed_contains?(feed, post, current_user: me)

  # a feed of media has media for rows, with no activity for `feed_contains?/3` to read
  defp row_ids(%{edges: edges}), do: MapSet.new(edges, &id/1)

  test "without a media filter all three are there, so the filter is what makes the difference",
       ctx do
    feed = posts(ctx.me, %{})

    assert contains?(feed, ctx.me, ctx.with_image)
    assert contains?(feed, ctx.me, ctx.with_video)
    assert contains?(feed, ctx.me, ctx.plain)
  end

  test "asking for a media type gives the media of that type", ctx do
    ids = posts(ctx.me, %{media_types: ["image"]}) |> row_ids()

    assert id(ctx.image) in ids
    refute id(ctx.video) in ids
  end

  test "asking for any media gives every media", ctx do
    ids = posts(ctx.me, %{media_types: ["*"]}) |> row_ids()

    assert id(ctx.image) in ids
    assert id(ctx.video) in ids
  end

  test "excluding a media type leaves it out, and keeps what carries no media at all", ctx do
    feed = posts(ctx.me, %{exclude_media_types: ["image"]})

    refute contains?(feed, ctx.me, ctx.with_image)
    assert contains?(feed, ctx.me, ctx.with_video)
    assert contains?(feed, ctx.me, ctx.plain)
  end

  test "excluding any media keeps only what carries none", ctx do
    feed = posts(ctx.me, %{exclude_media_types: ["*"]})

    assert contains?(feed, ctx.me, ctx.plain)
    refute contains?(feed, ctx.me, ctx.with_image)
    refute contains?(feed, ctx.me, ctx.with_video)
  end
end
