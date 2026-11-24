# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.URLPreviewLiveTest do
  @moduledoc """
  Link previews fetched from the real site, with no mocks, to check that our whole fetch path (the AP-aware fetch, its redirects, the HTML parsers) gets what a browser gets.

  It reaches the network, so it is tagged `:integration` and only runs when asked for. `FEDERATE=yes` makes the test env use the real HTTP adapters (the ones prod uses) instead of `Tesla.Mock`:

      FEDERATE=yes just test_run --only integration extensions/bonfire_files/test/url_preview_live_test.exs

  The YouTube video has embedding turned off, so its oEmbed endpoint answers 401 and the preview comes from the page's OpenGraph and Twitter tags only. If the video is deleted, the test needs another such URL.
  """
  use Bonfire.DataCase, async: false
  @moduletag :integration

  alias Bonfire.Files.Media

  @youtube_live_url "https://youtube.com/live/FNqRMKlybO8"

  test "a YouTube live link gets a title and a cover image" do
    me = fake_user!()

    assert [%Media{id: id}] = Media.maybe_fetch_and_save(me, [@youtube_live_url])

    # read back from the DB, as the UI does: the returned struct still has the atom keys of the fetched metadata
    assert {:ok, %Media{id: ^id} = media} = Media.get_by_url(@youtube_live_url)

    label = Media.media_label(media)
    assert is_binary(label), "no title in #{inspect(media.metadata)}"
    assert label =~ "Info session"

    image = Media.metadata_image_url(media)
    assert is_binary(image), "no image in #{inspect(media.metadata)}"
    assert image =~ "i.ytimg.com"
  end
end
