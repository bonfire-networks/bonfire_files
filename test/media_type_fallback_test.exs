# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.MediaTypeFallbackTest do
  @moduledoc """
  bonfire-app#1728: an incoming federated attachment whose concrete media file/type can't be
  resolved (e.g. a still-transcoding PeerTube Video — no playable mp4) was crashing the
  `Bonfire.Files.Media` insert with `media_type: can't be blank`. We now fall back to `"remote"`
  ONLY when no real source provides a (non-blank) media_type.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend
  import Tesla.Mock

  alias Bonfire.Files.Media

  setup do
    # the full ingestion path may make outgoing HTTP (publish/federation) in spawned processes —
    # irrelevant to #1728, so stub everything to 404.
    mock_global(fn _ -> %Tesla.Env{status: 404, body: ""} end)
    :ok
  end

  test "falls back to 'remote' when no media_type is provided anywhere" do
    creator = fake_user!()

    assert {:ok, media} =
             Media.insert(creator, "https://example.test/videos/watch/abc", %{size: 0}, %{})

    assert media.media_type == "remote"
    # NOTE: `path` is intentionally nulled by changeset/3 when remote_url resolves to an http URL
    # (avoids persisting expiring presigned URLs); real federated media keep their path — asserted
    # in the federation test. This unit test only pins the #1728 media_type fallback.
  end

  test "treats a blank-string media_type as missing and falls back to 'remote'" do
    creator = fake_user!()

    assert {:ok, media} =
             Media.insert(creator, "https://example.test/x", %{size: 0, media_type: ""}, %{})

    assert media.media_type == "remote"
  end

  test "preserves a real media_type (does NOT override with 'remote')" do
    creator = fake_user!()

    assert {:ok, media} =
             Media.insert(
               creator,
               "https://example.test/v.mp4",
               %{size: 123, media_type: "video/mp4"},
               %{}
             )

    assert media.media_type == "video/mp4"
  end

  test "ingests a still-transcoding PeerTube Video (real #1728 AP JSON, no playable file)" do
    # The real payload from the issue: waitTranscoding=true, url has only text/html + an
    # application/x-mpegURL HLS playlist with no nested mp4 → extract_best_video_url finds no
    # playable file → media_type would be blank. No HTTP needed (extraction is pure data).
    video =
      "fixtures/peertube-video-transcoding.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    creator = fake_user!()

    # `:public` is normally set by the AP layer's normalisation (the video is addressed to Public);
    # set it here since we're calling the ingestion directly with the raw object.
    object = %{data: video, public: true}

    # no `media_type: can't be blank` crash (the #1728 federation error) — ingestion succeeds:
    assert {:ok, _activity} = Media.ap_receive_activity(creator, object, object)

    # find THIS video's Media (by its stored json_ld id) and confirm it got the fallback type
    assert {:ok, medias} = Media.many([])

    media =
      Enum.find(medias, fn m -> get_in(m.metadata || %{}, ["json_ld", "id"]) == video["id"] end)

    assert media, "the transcoding video's Media should have been created"
    assert media.media_type == "remote"
  end

  describe "an incoming attachment with no media type" do
    # as `Bonfire.Files.ap_receive_attachments/3` gets each one; the unfurl of a `Link` finds nothing (404, mocked above)
    defp receive_attachment(attachment) do
      case Bonfire.Files.ap_receive_attachments(fake_user!(), false, attachment) do
        [%Media{} = media] -> media
        %Media{} = media -> media
      end
    end

    test "an unnamed Link to a file gets its type from the file's extension" do
      media =
        receive_attachment(%{"type" => "Link", "href" => "https://stats.example.test/a.png"})

      assert media.media_type == "image/png"
    end

    test "an unnamed Link with no extension (eg. a Bluesky blob) is a remote file of unknown type" do
      media =
        receive_attachment(%{
          "type" => "Link",
          "href" => "https://pds.example.test/xrpc/com.atproto.sync.getBlob?did=did:plc:a&cid=b"
        })

      assert media.media_type == "remote"
    end

    test "a named Link is a link" do
      media =
        receive_attachment(%{
          "type" => "Link",
          "href" => "https://example.test/stream",
          "name" => "Watch the stream"
        })

      assert media.media_type == "link"
    end

    test "an Image with no media type gets one from its file's extension, and is saved" do
      media =
        receive_attachment(%{"type" => "Image", "url" => "https://example.test/a/photo.jpg"})

      assert media.media_type == "image/jpeg"
    end

    test "control: a given media type is kept" do
      assert receive_attachment(%{
               "type" => "Document",
               "mediaType" => "video/webm",
               "url" => "https://example.test/v.webm"
             }).media_type == "video/webm"
    end
  end
end
