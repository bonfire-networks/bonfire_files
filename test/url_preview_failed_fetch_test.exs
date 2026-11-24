# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.URLPreviewFailedFetchTest do
  @moduledoc """
  A link preview is saved as a Media only when the fetch got the page: a 2xx status, and a title, description, image or embed in its metadata. Otherwise the post keeps the plain link and no Media is created, so the next post of the same link fetches it again (a saved Media is the dedup key for its URL).
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend
  import Tesla.Mock

  alias Bonfire.Files.Media

  @url "https://youtube.com/live/FNqRMKlybO8"
  @youtube_page File.read!(Path.expand("fixtures/youtube_live_head.html", __DIR__))

  setup do
    # Faviconic fetches with Req, which Tesla.Mock does not intercept: answer its requests here so no test reaches the network
    Process.put(:req_adapter, fn request -> {request, Req.Response.new(status: 404)} end)

    :ok
  end

  # serves `body` with `status` for the YouTube page, and what YouTube serves for a video with embedding turned off for its oEmbed endpoint
  defp mock_youtube(status, body) do
    mock_global(fn
      %{method: :get, url: "https://www.youtube.com/oembed" <> _} ->
        %Tesla.Env{status: 401, body: "Unauthorized"}

      %{method: :get, url: "https://" <> rest} = env ->
        if String.starts_with?(rest, ["youtube.com/live/", "www.youtube.com/live/"]) do
          %Tesla.Env{env | status: status, headers: [{"content-type", "text/html"}], body: body}
        else
          %Tesla.Env{status: 404, body: ""}
        end

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)
  end

  test "a page with no title, description or image creates no Media" do
    me = fake_user!()

    mock_youtube(
      200,
      ~s(<html><head><link rel="icon" href="/favicon.ico"></head><body></body></html>)
    )

    assert [nil] = Media.maybe_fetch_and_save(me, [@url])
    assert {:error, :not_found} = Media.get_by_url(@url)
  end

  test "an error page creates no Media, even with a title" do
    me = fake_user!()

    mock_youtube(403, "<html><head><title>Access denied</title></head><body></body></html>")

    assert [nil] = Media.maybe_fetch_and_save(me, [@url])
    assert {:error, :not_found} = Media.get_by_url(@url)
  end

  test "a real page still creates a Media" do
    me = fake_user!()

    mock_youtube(200, @youtube_page)

    assert [%Media{id: id}] = Media.maybe_fetch_and_save(me, [@url])

    assert_stored_youtube_preview(id)
  end

  test "a failed fetch doesn't block a later one" do
    me = fake_user!()

    mock_youtube(
      200,
      ~s(<html><head><link rel="icon" href="/favicon.ico"></head><body></body></html>)
    )

    Media.maybe_fetch_and_save(me, [@url])

    mock_youtube(200, @youtube_page)

    assert [%Media{id: id}] = Media.maybe_fetch_and_save(me, [@url])

    assert_stored_youtube_preview(id)
  end

  # reads the Media back from the DB, as the UI does: the struct `maybe_fetch_and_save` returns still has the atom keys of the fetched metadata, which the metadata accessors (reading string keys) don't see
  defp assert_stored_youtube_preview(id) do
    assert {:ok, %Media{id: ^id} = media} = Media.get_by_url(@url)

    label = Media.media_label(media)
    assert is_binary(label), "no title in #{inspect(media.metadata)}"
    assert label =~ "Are you getting fired?"

    image = Media.metadata_image_url(media)
    assert is_binary(image), "no image in #{inspect(media.metadata)}"
    assert image =~ "https://i.ytimg.com/"
  end
end
