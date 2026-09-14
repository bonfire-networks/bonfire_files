defmodule Bonfire.Files.MastoApi.WavTest do
  use Bonfire.Files.MastoApiCase, async: false

  doctest Bonfire.Files.MimeTypes, only: [normalize_type: 1]

  @moduletag :masto_api
  @moduletag capture_log: true
  @wav Path.expand("../../fixtures/tone.wav", __DIR__)

  test "WAV metadata matches the advertised canonical MIME type" do
    assert {:ok, %{media_type: "audio/wav"}} = Bonfire.Files.extract_metadata(@wav)
  end

  test "WAV upload publishes an audio attachment even with an untrusted client MIME", %{
    conn: conn
  } do
    account = Bonfire.Me.Fake.fake_account!()
    user = Bonfire.Me.Fake.fake_user!(account)
    conn = masto_api_conn(conn, user: user, account: account)

    upload = %Plug.Upload{
      path: @wav,
      filename: "tone.wav",
      content_type: "application/octet-stream"
    }

    media =
      conn
      |> put_req_header("content-type", "multipart/form-data")
      |> post("/api/v1/media", %{"file" => upload})
      |> json_response(200)

    assert media["type"] == "audio"
    assert {:ok, %{media_type: "audio/wav"}} = Bonfire.Files.Media.one(id: media["id"])

    status =
      conn
      |> post("/api/v1/statuses", %{
        "status" => "WAV playback",
        "visibility" => "public",
        "media_ids" => [media["id"]]
      })
      |> json_response(200)

    read = conn |> get("/api/v1/statuses/#{status["id"]}") |> json_response(200)
    assert [%{"type" => "audio", "id" => id}] = read["media_attachments"]
    assert id == media["id"]
  end
end
