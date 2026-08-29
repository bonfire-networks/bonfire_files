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

    # AS2 `summary` is the object's own precis, and it is what Bonfire itself sends when a link Media federates as a `Page` (see `Media.ap_publish_activity/3`). Not reading it back meant a link's description made the round trip intact and then had nowhere to be displayed from.
    test "uses AS2 `summary` as the description" do
      metadata = %{"json_ld" => %{"type" => "Page", "summary" => "what the link is about"}}

      assert Media.description(metadata) == "what the link is about"
    end

    test "AS2 `summary` is preferred over the raw body" do
      metadata = %{
        "json_ld" => %{"summary" => "what the link is about", "content" => "the body of the post"}
      }

      assert Media.description(metadata) == "what the link is about"
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

  # JSON-LD is an array as often as it is a single object (`@graph`, or a page that describes several entities), which is why `Files.is_research?/2` bothers to handle both. Reading a key out of one needs `ed`: the `e` macro asks Pathex for a path, and Pathex can't index a list by
  # a string key.
  describe "an ActivityPub/JSON-LD object that arrives as a list" do
    test "media_label/1 finds the title" do
      metadata = %{"json_ld" => [%{"type" => "Page", "name" => "The post's title"}]}

      assert Media.media_label(metadata) == "The post's title"
    end

    test "description/1 finds the summary" do
      metadata = %{"json_ld" => [%{"type" => "Page", "summary" => "what the link is about"}]}

      assert Media.description(metadata) == "what the link is about"
    end

    test "description/1 finds the body" do
      metadata = %{"json_ld" => [%{"type" => "Page", "content" => "the body of the post"}]}

      assert Media.description(metadata) == "the body of the post"
    end

    test "media_label/1 searches past entries that don't carry a title" do
      metadata = %{
        "json_ld" => [
          %{"type" => "BreadcrumbList"},
          %{"type" => "Article", "name" => "The article's title"}
        ]
      }

      assert Media.media_label(metadata) == "The article's title"
    end
  end

  describe "preview_image_url/1" do
    test "reads a cover image nested under an AS2 `image` object" do
      metadata = %{"image" => %{"type" => "Image", "url" => "https://example.com/og.jpg"}}

      assert Media.preview_image_url(%{metadata: metadata}) == "https://example.com/og.jpg"
    end

    # AS2 lets `image` be an array of Images, and returning the whole Image object (rather than its
    # url) puts a map where every caller expects a URL string
    test "reads a cover image out of an `image` list" do
      metadata = %{"image" => [%{"type" => "Image", "url" => "https://example.com/og.jpg"}]}

      assert Media.preview_image_url(%{metadata: metadata}) == "https://example.com/og.jpg"
    end

    # what a link Media looks like once it has been received: the whole AS2 object sits in `json_ld`, cover image included, so reading only the top-level `image` finds nothing
    test "reads the cover image of a received AS2 object" do
      metadata = %{
        "json_ld" => %{
          "type" => "Page",
          "url" => "https://example.com/some/article",
          "image" => %{"type" => "Image", "url" => "https://example.com/og.jpg"}
        }
      }

      assert Media.preview_image_url(%{metadata: metadata}) == "https://example.com/og.jpg"
    end

    test "a favicon republished as the cover image is not treated as one" do
      metadata = %{
        "favicon" => "https://example.com/favicon.ico",
        "other" => %{"og:image" => "https://example.com/favicon.ico"}
      }

      assert Media.preview_image_url(%{metadata: metadata}) == nil
    end
  end
end
