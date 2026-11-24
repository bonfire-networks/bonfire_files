# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.URLPreviewPlayerDiscoveryTest do
  @moduledoc """
  A link preview finds a page's player as the page declares it, so the link can play in place: its oEmbed from a `<link>` of type `application/json+oembed`, `text/json+oembed` (SoundCloud's) or `text/xml+oembed` (asked for as JSON), and its Twitter card from `<meta name=…>` or `<meta property=…>` (SoundCloud's).

  The oEmbed providers list is unavailable here (as it may be on an instance), so the page's own `<link>` is what's left.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend
  import Tesla.Mock

  alias Bonfire.Files.Media

  @url "https://soundcloud.com/someone/a-track"
  @player "https://w.soundcloud.com/player/?url=https%3A%2F%2Fapi.soundcloud.com%2Ftracks%2F1"
  @oembed %{
    "version" => 1.0,
    "type" => "rich",
    "provider_name" => "SoundCloud",
    "title" => "A track",
    "height" => 400,
    "html" =>
      ~s(<iframe width="100%" height="400" scrolling="no" frameborder="no" src="#{@player}"></iframe>)
  }

  setup do
    # Faviconic fetches with Req, which Tesla.Mock does not intercept
    Process.put(:req_adapter, fn request -> {request, Req.Response.new(status: 404)} end)
    :ok
  end

  # SoundCloud's page head, as it is: its oEmbed as `text/xml+oembed` and `text/json+oembed`, its Twitter card with `property=`
  defp page(links) do
    ~s(<html><head><title>A track</title><meta property="og:title" content="A track"><meta property="twitter:card" content="player"><meta property="twitter:player" content="#{@player}"><meta property="twitter:player:height" content="400">#{links}</head><body></body></html>)
  end

  defp mock_page(links) do
    mock_global(fn
      %{method: :get, url: "https://soundcloud.com/oembed" <> rest} ->
        # JSON only when asked for it, as SoundCloud does
        if String.contains?(rest, "format=json"),
          do: %Tesla.Env{
            status: 200,
            headers: [{"content-type", "application/json"}],
            body: Jason.encode!(@oembed)
          },
          else: %Tesla.Env{
            status: 200,
            headers: [{"content-type", "text/xml"}],
            body: "<oembed><type>rich</type></oembed>"
          }

      %{method: :get, url: @url} = env ->
        %Tesla.Env{env | status: 200, headers: [{"content-type", "text/html"}], body: page(links)}

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)
  end

  defp oembed_link(type, format),
    do:
      ~s(<link rel="alternate" type="#{type}" href="https://soundcloud.com/oembed?url=#{URI.encode_www_form(@url)}&amp;format=#{format}">)

  test "a page declaring its oEmbed as text/json+oembed (and text/xml+oembed) gets it" do
    mock_page(oembed_link("text/xml+oembed", "xml") <> oembed_link("text/json+oembed", "json"))

    assert [%Media{id: id}] = Media.maybe_fetch_and_save(fake_user!(), [@url])
    {:ok, media} = Media.get_by_url(@url)
    assert id == media.id

    assert %{"type" => "rich", "html" => html} = media.metadata["oembed"]
    assert html =~ @player
  end

  test "a page declaring its oEmbed only as text/xml+oembed gets it as JSON" do
    mock_page(oembed_link("text/xml+oembed", "xml"))

    assert [%Media{}] = Media.maybe_fetch_and_save(fake_user!(), [@url])
    {:ok, media} = Media.get_by_url(@url)

    assert %{"type" => "rich"} = media.metadata["oembed"]
  end

  test "a Twitter card declared with property= is read" do
    mock_page("")

    assert [%Media{}] = Media.maybe_fetch_and_save(fake_user!(), [@url])
    {:ok, media} = Media.get_by_url(@url)

    assert @player == get_in(media.metadata, ["twitter", "player"]) || media.metadata["twitter"]
  end

  test "control: a page declaring application/json+oembed still gets it" do
    mock_page(oembed_link("application/json+oembed", "json"))

    assert [%Media{}] = Media.maybe_fetch_and_save(fake_user!(), [@url])
    {:ok, media} = Media.get_by_url(@url)

    assert %{"type" => "rich"} = media.metadata["oembed"]
  end
end
