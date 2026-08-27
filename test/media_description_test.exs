# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.MediaDescriptionTest do
  @moduledoc """
  `Media.description/1` resolves the body text shown under a media preview (`MediaLinkLive` renders
  it via `data-id="media_description"`).

  Its fallback chain reaches into `metadata.json_ld`, which for federated media holds the whole
  incoming ActivityPub object. AS2 puts an object's body in `content`, so a threadiverse thread
  starter that becomes Media (a Lemmy `Page` with an image or a link, which carries a real title and
  body) keeps its text in metadata but had no way to display it until `content` joined the chain.
  """
  use Bonfire.DataCase, async: true

  alias Bonfire.Files.Media

  describe "description/1 from an ActivityPub object" do
    test "uses AS2 `content` as the body" do
      metadata = %{"json_ld" => %{"type" => "Page", "content" => "the body of the post"}}

      assert Media.description(metadata) == "the body of the post"
      assert Media.description(%{metadata: metadata}) == "the body of the post"
    end

    test "an explicit description still wins over `content`" do
      metadata = %{
        "description" => "set by the uploader",
        "json_ld" => %{"content" => "the body of the post"}
      }

      assert Media.description(metadata) == "set by the uploader",
             "a user-supplied description is more specific than the source object's body"
    end

    # `content` sits LATE in the chain deliberately: a purpose-made summary (OG description,
    # oEmbed abstract, atom summary) describes the link better than dumping the whole body, so
    # `content` is what's used when nothing more suitable was found.
    test "a purpose-made summary is preferred over the raw body" do
      metadata = %{
        "json_ld" => %{"content" => "the body of the post", "headline" => "a headline"}
      }

      assert Media.description(metadata) == "a headline"
    end

    test "objects with no body fall through rather than returning empty" do
      metadata = %{"json_ld" => %{"type" => "Page", "name" => "just a title"}}

      refute Media.description(metadata) == ""
    end
  end

  describe "media_label/1 from an ActivityPub object" do
    # the counterpart: the title rendered as `data-id="media_title"`
    test "uses AS2 `name` as the title" do
      metadata = %{"json_ld" => %{"type" => "Page", "name" => "The post's title"}}

      assert Media.media_label(metadata) == "The post's title"
    end

    # an attachment's `name` is its caption/alt text, which titles the media better than it
    # describes it — so it's a label fallback, for objects that carry no `name` of their own
    test "falls back to an attachment's name when the object has no title" do
      metadata = %{
        "json_ld" => %{"type" => "Page", "attachment" => [%{"name" => "an attachment caption"}]}
      }

      assert Media.media_label(metadata) == "an attachment caption"
    end

    test "the object's own name beats an attachment caption" do
      metadata = %{
        "json_ld" => %{
          "name" => "The post's title",
          "attachment" => [%{"name" => "an attachment caption"}]
        }
      }

      assert Media.media_label(metadata) == "The post's title"
    end
  end
end
