defmodule Bonfire.Files.MastoApi.LinkPreviewTest do
  use Bonfire.Files.MastoApiCase, async: false

  alias Bonfire.Files.Media

  doctest Bonfire.API.MastoCompat.Mappers.PreviewCard

  @moduletag :masto_api
  @moduletag capture_log: true

  setup %{conn: conn} do
    account = Bonfire.Me.Fake.fake_account!()
    user = Bonfire.Me.Fake.fake_user!(account)
    {:ok, user: user, api_conn: masto_api_conn(conn, user: user, account: account)}
  end

  test "website metadata becomes a card in GraphQL status reads", context do
    link = create_link(context.user, %{"image" => %{"url" => "https://example.org/cover.png"}})
    status = publish(context, [link])

    assert status["card"]["url"] == link.path
    assert status["card"]["title"] == "Preview title"
    assert status["card"]["description"] == "Preview description"
    assert status["card"]["image"] == "https://example.org/cover.png"
    assert status["media_attachments"] == []
  end

  test "links without cover images still produce text cards", context do
    link = create_link(context.user, %{})
    status = publish(context, [link])

    assert status["card"]["title"] == "Preview title"
    assert status["card"]["image"] == nil
    assert status["media_attachments"] == []
  end

  test "a link card preserves uploaded image attachments", context do
    link = create_link(context.user, %{})

    {:ok, image} =
      Bonfire.Files.upload(
        Bonfire.Files.ImageUploader,
        context.user,
        Bonfire.Files.Simulation.image_file(),
        %{}
      )

    status = publish(context, [link, image])

    assert status["card"]["url"] == link.path
    assert [%{"id" => id, "type" => "image"}] = status["media_attachments"]
    assert id == image.id
  end

  test "a link with a video player (video/embed) is the card, not a video attachment", context do
    link =
      create_link(context.user, %{}, "video/embed", %{
        "content_type" => nil,
        "oembed" => %{
          "type" => "video",
          "html" => ~s(<iframe src="https://www.youtube.com/embed/abc"></iframe>)
        }
      })

    status = publish(context, [link])

    assert status["card"]["url"] == link.path
    assert status["media_attachments"] == []
  end

  defp create_link(user, extra, media_type \\ "website", extra_metadata \\ %{}) do
    url = "https://example.org/#{Faker.UUID.v4()}"

    {:ok, media} =
      Media.insert(user, url, %{media_type: media_type, size: 0}, %{
        url: url,
        metadata:
          Map.merge(
            %{
              "content_type" => "text/html",
              "facebook" =>
                Map.merge(
                  %{"title" => "Preview title", "description" => "Preview description"},
                  extra
                )
            },
            extra_metadata
          )
      })

    media
  end

  # read through the API: an Ecto post passed to `Status.from_post/2` has no account, as accounts come from GraphQL only
  defp publish(%{user: user, api_conn: conn}, media) do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: user,
        boundary: "public",
        post_attrs: %{
          post_content: %{html_body: "Link preview regression"},
          uploaded_media: media
        }
      )

    conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)
  end
end
