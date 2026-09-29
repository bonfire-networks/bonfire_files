# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.MediaCanonicalTest do
  @moduledoc """
  Junk `<link rel="canonical">` values must not become a Media's identity `path`.

  A canonical is a dedup key: every URL whose page reports the same canonical reuses one Media. So a bogus value shared by many pages (eg. YouTube serving our server `href="undefined"`, resolved to `https://www.youtube.com/undefined`) collapses every link on that site into whichever preview was fetched first.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Files.Media

  for junk <- ["undefined", "null", "[object Object]", "{{canonical}}", "javascript:void(0)", ""] do
    test "a #{inspect(junk)} canonical is ignored, so distinct pages keep distinct previews" do
      me = fake_user!()

      a =
        Media.maybe_save(me, "https://www.youtube.com/watch?v=aaaaaaaaaaa", %{
          canonical_url: unquote(junk)
        })

      b =
        Media.maybe_save(me, "https://www.youtube.com/watch?v=bbbbbbbbbbb", %{
          canonical_url: unquote(junk)
        })

      assert a.path == "https://www.youtube.com/watch?v=aaaaaaaaaaa"
      assert b.path == "https://www.youtube.com/watch?v=bbbbbbbbbbb"
      refute a.id == b.id
    end
  end

  test "a canonical pointing at the site root is ignored for a deeper page" do
    me = fake_user!()

    a = Media.maybe_save(me, "https://news.example.com/2026/story-a", %{canonical_url: "/"})

    b =
      Media.maybe_save(me, "https://news.example.com/2026/story-b", %{
        canonical_url: "https://news.example.com/"
      })

    assert a.path == "https://news.example.com/2026/story-a"
    assert b.path == "https://news.example.com/2026/story-b"
    refute a.id == b.id
  end

  test "a legitimate canonical still dedups variants of one page" do
    me = fake_user!()

    a =
      Media.maybe_save(me, "https://www.youtube.com/watch?v=ccccccccccc&t=33s", %{
        canonical_url: "https://www.youtube.com/watch?v=ccccccccccc"
      })

    b =
      Media.maybe_save(me, "https://www.youtube.com/watch?list=PLx&v=ccccccccccc", %{
        canonical_url: "https://www.youtube.com/watch?v=ccccccccccc"
      })

    assert a.path == "https://www.youtube.com/watch?v=ccccccccccc"
    assert a.id == b.id
  end

  test "a relative canonical is still resolved against the source url" do
    me = fake_user!()

    media =
      Media.maybe_save(me, "https://blog.example.com/posts/hello?ref=x", %{
        canonical_url: "/posts/hello"
      })

    assert media.path == "https://blog.example.com/posts/hello"
  end
end
