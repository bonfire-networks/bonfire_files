# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.MediaUrlSlashTest do
  @moduledoc """
  Trailing-slash handling for `Media.get_by_url/1`.

  The identity `path` (the canonical) stays EXACT: never slash-mangled, so two genuinely-different pages `/x` and `/x/` keep separate objects and each wins its own exact `get_by_path`. The `metadata["urls"]` list is only a lookup index, so its entries are slash-stripped, letting a guest on either `/post` or `/post/` find the one anchor.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Files.Media

  test "an object stored from a URL WITH a trailing slash is found by the slash-less variant" do
    me = fake_user!()
    url = "https://blog.example.com/post/"

    assert media = Media.maybe_save(me, url, %{})
    assert media.path == url

    assert {:ok, %{id: id}} = Media.get_by_url("https://blog.example.com/post")
    assert id == media.id
    assert {:ok, %{id: ^id}} = Media.get_by_url(url)
  end

  test "an object stored WITHOUT a trailing slash is found by the slash variant" do
    me = fake_user!()
    url = "https://blog.example.com/post"

    assert media = Media.maybe_save(me, url, %{})
    assert media.path == url

    assert {:ok, %{id: id}} = Media.get_by_url("https://blog.example.com/post/")
    assert id == media.id
  end

  test "a media_uri differing from the canonical only by a trailing slash (and tracking) still resolves" do
    me = fake_user!()

    assert media =
             Media.maybe_save(me, "https://blog.example.com/page/?utm_source=x", %{
               canonical_url: "https://blog.example.com/canonical"
             })

    assert media.path == "https://blog.example.com/canonical"

    assert {:ok, %{id: id}} = Media.get_by_url("https://blog.example.com/page")
    assert id == media.id
    assert {:ok, %{id: ^id}} = Media.get_by_url("https://blog.example.com/page/")
  end

  test "exact canonical path wins, so two pages differing only by a trailing slash stay separate" do
    me = fake_user!()

    a = Media.maybe_save(me, "https://blog.example.com/x", %{})
    b = Media.maybe_save(me, "https://blog.example.com/x/", %{})

    refute a.id == b.id

    assert {:ok, %{id: a_id}} = Media.get_by_url("https://blog.example.com/x")
    assert a_id == a.id

    assert {:ok, %{id: b_id}} = Media.get_by_url("https://blog.example.com/x/")
    assert b_id == b.id
  end

  test "a url recorded only in metadata[\"urls\"] is found by get_by_url/1 (the indexed predicate)" do
    me = fake_user!()

    # the canonical becomes the `path`; the differing media_uri lands only in metadata["urls"], so this
    # drives get_by_source_url/1 — the `metadata -> 'urls' ? $1` predicate the partial GIN index serves
    media =
      Media.maybe_save(me, "https://blog.example.com/page?utm_x=1", %{
        canonical_url: "https://blog.example.com/canonical"
      })

    assert media.path == "https://blog.example.com/canonical"
    assert {:ok, %{id: id}} = Media.get_by_url("https://blog.example.com/page")
    assert id == media.id
  end
end
