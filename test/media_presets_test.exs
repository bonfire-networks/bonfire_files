defmodule Bonfire.Files.MediaPresetsTest do
  @moduledoc """
  The images, videos, audio and documents feeds list the media of their kind, files and embeds together (a video file and a link with a video player are both in videos), and no link preview, paper or other kind of file.
  """
  use Bonfire.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Me.Fake
  import Bonfire.Posts.Fake

  setup do
    Process.put([:bonfire, :default_pagination_limit], 20)

    me = Fake.fake_user!()

    # each saved as the extension saves them: files by their MIME type, link previews by the kind `Bonfire.Files.link_type/2` gives
    media =
      Map.new(
        [
          image: "image/png",
          video_file: "video/mp4",
          audio_file: "audio/mpeg",
          pdf: "application/pdf",
          video_embed: "video/embed",
          audio_embed: "audio/embed",
          document_embed: "document/embed",
          link: "link",
          research: "research"
        ],
        fn {name, media_type} ->
          url = "https://example.org/#{name}/#{Faker.UUID.v4()}"

          {:ok, media} =
            Bonfire.Files.Media.insert(me, url, %{media_type: media_type, size: 0}, %{
              url: url,
              metadata:
                if(name in [:video_embed, :audio_embed, :document_embed, :link, :research],
                  do: %{"content_type" => "text/html"},
                  else: %{}
                )
            })

          fake_post!(me, "public", %{
            post_content: %{html_body: "a #{name}"},
            uploaded_media: [media]
          })

          {name, id(media)}
        end
      )

    %{me: me, media: media}
  end

  defp listed(ctx, preset) do
    %{edges: edges} = FeedLoader.feed(preset, %{}, current_user: ctx.me)
    MapSet.new(edges, &id/1)
  end

  defp assert_lists(ctx, preset, expected) do
    ids = listed(ctx, preset)

    for {name, id} <- ctx.media do
      if name in expected,
        do: assert(id in ids, "/feed/#{preset} should list #{name}"),
        else: refute(id in ids, "/feed/#{preset} should not list #{name}")
    end
  end

  test("images lists images", ctx, do: assert_lists(ctx, :images, [:image]))

  test("videos lists video files and video embeds", ctx,
    do: assert_lists(ctx, :videos, [:video_file, :video_embed])
  )

  test("audio lists audio files and audio embeds", ctx,
    do: assert_lists(ctx, :audio, [:audio_file, :audio_embed])
  )

  test("documents lists document files and document embeds, not a paper or a link", ctx,
    do: assert_lists(ctx, :documents, [:pdf, :document_embed])
  )

  test("research lists papers, and no document", ctx,
    do: assert_lists(ctx, :research, [:research])
  )
end
