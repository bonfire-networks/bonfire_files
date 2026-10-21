# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ApIconUrlTest do
  @moduledoc """
  `Media.extract_ap_icon_url/1` turns any ActivityStreams image value into one URL string.

  AS2 lets an `icon` or `image` be a URL string, an Image/Link object, or a list of them, and lets the object's `url` be a string, a Link object or a list too. A shape that is not unwrapped reaches `Bonfire.Files.upload/5` as a map and raises a `FunctionClauseError` there.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Files.Media

  @url "https://a.local/i.png"
  @big "https://a.local/big.png"
  @small "https://a.local/small.png"

  test "a plain URL string is returned as is" do
    assert @url == Media.extract_ap_icon_url(@url)
  end

  test "an Image object with a string url" do
    assert @url == Media.extract_ap_icon_url(%{"type" => "Image", "url" => @url})
  end

  test "a Link object with an href" do
    assert @url == Media.extract_ap_icon_url(%{"type" => "Link", "href" => @url})
  end

  test "an Image object whose url is a Link object (as sent by 9.dev.bonfire.cafe)" do
    assert @url ==
             Media.extract_ap_icon_url(%{
               "type" => "Image",
               "url" => %{"type" => "Link", "href" => @url, "mediaType" => "image/png"}
             })
  end

  test "an Image object whose url is a list of strings" do
    assert @url == Media.extract_ap_icon_url(%{"type" => "Image", "url" => [@url]})
  end

  test "an Image object whose url is a list of Links picks the largest" do
    assert @big ==
             Media.extract_ap_icon_url(%{
               "type" => "Image",
               "url" => [
                 %{"type" => "Link", "href" => @small, "width" => 10, "height" => 10},
                 %{"type" => "Link", "href" => @big, "width" => 100, "height" => 100}
               ]
             })
  end

  test "a list of Images picks the largest" do
    assert @big ==
             Media.extract_ap_icon_url([
               %{"type" => "Image", "url" => @small, "width" => 10, "height" => 10},
               %{"type" => "Image", "url" => @big, "width" => 100, "height" => 100}
             ])
  end

  test "nothing usable gives nil" do
    assert nil == Media.extract_ap_icon_url(nil)
    assert nil == Media.extract_ap_icon_url(%{})
    assert nil == Media.extract_ap_icon_url(%{"type" => "Image"})
    assert nil == Media.extract_ap_icon_url(%{"type" => "Image", "url" => nil})
    assert nil == Media.extract_ap_icon_url([])
  end
end
