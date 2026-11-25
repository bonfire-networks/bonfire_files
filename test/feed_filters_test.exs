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

  # both halves, each on its own: a key with no field is dropped by the cast, and a field with no module validates and filters nothing, and either way every test below just sees an unfiltered feed
  test "the filters' keys are fields on FeedFilters, declared from this extension's config" do
    fields = Bonfire.Social.FeedFilters.__schema__(:fields)

    # what the config holds now against what the schema was compiled with, so a failure says which one lacks the field: the config (where it is declared) or the build (which reads it when `bonfire_social` compiles)
    seen =
      "config: #{inspect(Application.get_env(:bonfire_social, Bonfire.Social.FeedFilters)[:field])}, schema fields: #{inspect(fields)}"

    assert :media_types in fields, seen
    assert :exclude_media_types in fields, seen
  end

  test "the module that applies them is registered with the feed loader" do
    assert Bonfire.Files.FeedFilters in Bonfire.Common.FeedFilterModule.modules()
  end

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

  # a link preview as `link_preview_test.exs` stores one
  defp link_media(user, media_type) do
    url = "https://example.org/#{Faker.UUID.v4()}"

    {:ok, media} =
      Bonfire.Files.Media.insert(user, url, %{media_type: media_type, size: 0}, %{
        url: url,
        metadata: %{"content_type" => "text/html"}
      })

    media
  end

  # a remote file, as an incoming attachment stores one: its MIME type and no page metadata
  defp file_media(user, media_type) do
    url = "https://files.example.org/#{Faker.UUID.v4()}"

    {:ok, media} =
      Bonfire.Files.Media.insert(user, url, %{media_type: media_type, size: 0}, %{url: url})

    media
  end

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

  test "asking for attachments gives every media except link previews", ctx do
    link = link_media(ctx.me, "website")
    html_typed_link = link_media(ctx.me, "video.other")
    fake_post!(ctx.me, "public", %{post_content: %{html_body: "a link"}, uploaded_media: [link]})

    fake_post!(ctx.me, "public", %{
      post_content: %{html_body: "a link stored under another type"},
      uploaded_media: [html_typed_link]
    })

    ids = posts(ctx.me, %{media_types: ["attachment"]}) |> row_ids()

    assert id(ctx.image) in ids
    assert id(ctx.video) in ids
    refute id(link) in ids
    refute id(html_typed_link) in ids
  end

  # a document is a file that isn't an image, video or audio; a link preview stored as `text/html` isn't one
  test "asking for documents gives a document, not a link preview stored as HTML", ctx do
    pdf_url = "https://example.org/#{Faker.UUID.v4()}.pdf"

    {:ok, pdf} =
      Bonfire.Files.Media.insert(ctx.me, pdf_url, %{media_type: "application/pdf", size: 0}, %{
        url: pdf_url
      })

    html_link = link_media(ctx.me, "text/html")

    fake_post!(ctx.me, "public", %{post_content: %{html_body: "a pdf"}, uploaded_media: [pdf]})

    fake_post!(ctx.me, "public", %{
      post_content: %{html_body: "a page"},
      uploaded_media: [html_link]
    })

    ids = posts(ctx.me, %{media_types: [:document]}) |> row_ids()

    assert id(pdf) in ids
    refute id(html_link) in ids
    refute id(ctx.image) in ids
  end

  # media with a file of ours (an upload, or an imported file with its storage), not a link preview or an embed, which are only a URL
  test "asking for media with a file gives uploads, not a link preview or an embed", ctx do
    preview = link_media(ctx.me, "website")
    embed = link_media(ctx.me, "video.other")

    fake_post!(ctx.me, "public", %{
      post_content: %{html_body: "a page"},
      uploaded_media: [preview]
    })

    fake_post!(ctx.me, "public", %{
      post_content: %{html_body: "a video page"},
      uploaded_media: [embed]
    })

    ids = posts(ctx.me, %{media_types: ["*"], media_has_file: true}) |> row_ids()

    assert id(ctx.image) in ids
    assert id(ctx.video) in ids
    refute id(preview) in ids
    refute id(embed) in ids
  end

  # the types media are stored with: `link`, `research`, `video/embed` and `audio/embed` for link previews (`Bonfire.Files.link_type/2`), a MIME type for files
  describe "by the stored type" do
    setup ctx do
      media =
        Map.new(
          [
            video_embed: "video/embed",
            audio_embed: "audio/embed",
            link: "link",
            research: "research",
            html_link: "text/html",
            hls: "application/x-mpegURL",
            pdf: "application/pdf",
            rtf: "application/rtf",
            document_embed: "document/embed"
          ],
          fn {name, media_type} ->
            media =
              if name in [:hls, :pdf, :rtf],
                do: file_media(ctx.me, media_type),
                else: link_media(ctx.me, media_type)

            fake_post!(ctx.me, "public", %{
              post_content: %{html_body: "a #{name}"},
              uploaded_media: [media]
            })

            {name, id(media)}
          end
        )

      %{media: media}
    end

    defp listed(ctx, filters), do: posts(ctx.me, filters) |> row_ids()

    defp assert_lists(ctx, filters, expected) do
      ids = listed(ctx, filters)
      all = Map.merge(ctx.media, %{image: id(ctx.image), video: id(ctx.video)})

      for {name, id} <- all do
        if name in expected,
          do: assert(id in ids, "#{inspect(filters)} should list #{name}"),
          else: refute(id in ids, "#{inspect(filters)} should not list #{name}")
      end
    end

    test "videos are video files, HLS streams and video embeds", ctx do
      assert_lists(ctx, %{media_types: ["video"]}, [:video, :video_embed, :hls])
    end

    test "audio is audio files and audio embeds", ctx do
      assert_lists(ctx, %{media_types: ["audio"]}, [:audio_embed])
    end

    test "links are link previews without a player", ctx do
      assert_lists(ctx, %{media_types: [:link]}, [:link, :html_link])
    end

    test "documents are document files and document embeds, not a stream or a page", ctx do
      assert_lists(ctx, %{media_types: [:document]}, [:pdf, :rtf, :document_embed])
    end

    test "attachments are files, not link previews, papers' pages or embeds", ctx do
      assert_lists(ctx, %{media_types: ["attachment"]}, [:image, :video, :hls, :pdf, :rtf])
    end
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
