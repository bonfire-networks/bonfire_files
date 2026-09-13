defmodule Bonfire.Files.MastoApi.PlaybackTest do
  use Bonfire.Files.MastoApiCase, async: false

  @moduletag :masto_api
  @moduletag capture_log: true

  setup %{conn: conn} do
    account = Bonfire.Me.Fake.fake_account!()
    user = Bonfire.Me.Fake.fake_user!(account)
    {:ok, api_conn: masto_api_conn(conn, user: user, account: account)}
  end

  test "raw GIFs remain images in upload and status responses", %{api_conn: conn} do
    upload = %Plug.Upload{
      path: Path.expand("../../fixtures/animation.gif", __DIR__),
      filename: "animation.gif",
      content_type: "image/gif"
    }

    media = upload_media(conn, upload)
    status = publish_media(conn, media)
    attachment = hd(status["media_attachments"])

    assert media["type"] == "image"
    assert attachment["type"] == "image"
    assert attachment["preview_url"] == attachment["url"]
  end

  test "video previews use the generated image through upload and GraphQL status reads", %{api_conn: conn} do
    file = Bonfire.Files.Simulation.video_file()
    upload = %Plug.Upload{path: file.path, filename: file.filename, content_type: "video/mp4"}
    media = upload_media(conn, upload)
    status = publish_media(conn, media)
    attachment = hd(status["media_attachments"])

    assert media["type"] == "video"
    assert is_binary(media["preview_url"])
    refute media["preview_url"] == media["url"]
    assert URI.parse(media["preview_url"]).path =~ ".jpg"
    assert attachment["preview_url"] == media["preview_url"]
    refute attachment["preview_url"] == attachment["url"]
  end

  test "a video without a thumbnail does not advertise its video URL as an image" do
    attachment = Bonfire.API.MastoCompat.Mappers.MediaAttachment.from_media(%{
      id: "remote-video", media_type: "video/mp4", url: "https://example.org/clip.mp4"
    })

    assert attachment["preview_url"] == nil
  end

  defp upload_media(conn, upload) do
    conn
    |> put_req_header("content-type", "multipart/form-data")
    |> post("/api/v1/media", %{"file" => upload})
    |> json_response(200)
  end

  defp publish_media(conn, media) do
    created = conn |> post("/api/v1/statuses", %{"status" => "Playback regression", "media_ids" => [media["id"]]}) |> json_response(200)
    conn |> get("/api/v1/statuses/#{created["id"]}") |> json_response(200)
  end
end
