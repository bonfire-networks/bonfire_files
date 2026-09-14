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

  test "website metadata becomes a card in creation and GraphQL status reads", context do
    link = create_link(context.user, %{"image" => %{"url" => "https://example.org/cover.png"}})
    {created, read} = publish(context, [link])

    for status <- [created, read] do
      assert status["card"]["url"] == link.path
      assert status["card"]["title"] == "Preview title"
      assert status["card"]["description"] == "Preview description"
      assert status["card"]["image"] == "https://example.org/cover.png"
      assert status["media_attachments"] == []
    end
  end

  test "links without cover images still produce text cards", context do
    link = create_link(context.user, %{})
    {_created, status} = publish(context, [link])

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

    {_created, status} = publish(context, [link, image])

    assert status["card"]["url"] == link.path
    assert [%{"id" => id, "type" => "image"}] = status["media_attachments"]
    assert id == image.id
  end

  defp create_link(user, extra) do
    url = "https://example.org/#{Faker.UUID.v4()}"

    {:ok, media} =
      Media.insert(user, url, %{media_type: "website", size: 0}, %{
        url: url,
        metadata: %{
          "content_type" => "text/html",
          "facebook" =>
            Map.merge(
              %{"title" => "Preview title", "description" => "Preview description"},
              extra
            )
        }
      })

    media
  end

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

    post =
      Bonfire.Common.Repo.preload(post, [:post_content, :media, :replied, activity: [:subject]])

    created = Bonfire.API.MastoCompat.Mappers.Status.from_post(post, current_user: user)
    read = conn |> get("/api/v1/statuses/#{post.id}") |> json_response(200)
    {created, read}
  end
end
