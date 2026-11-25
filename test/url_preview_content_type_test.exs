# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.URLPreviewContentTypeTest do
  @moduledoc """
  A link whose response isn't a web page is saved with the type the response says, so a PDF or an RTF is a document and not a link preview: from the `Content-Type` header, and from the URL's extension when the header isn't there.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend
  import Tesla.Mock

  alias Bonfire.Files.Media

  setup do
    # Faviconic fetches with Req, which Tesla.Mock does not intercept
    Process.put(:req_adapter, fn request -> {request, Req.Response.new(status: 404)} end)
    :ok
  end

  defp mock_response(content_type, body) do
    mock_global(fn
      %{method: :get, url: "https://files.example.test/" <> _} = env ->
        headers = if content_type, do: [{"content-type", content_type}], else: []
        %Tesla.Env{env | status: 200, headers: headers, body: body}

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)
  end

  test "a link whose response is a PDF is saved as a PDF, with no extension in its URL" do
    me = fake_user!()
    url = "https://files.example.test/download/4821"
    mock_response("application/pdf", "%PDF-1.4 a report")

    assert [%Media{media_type: "application/pdf"}] = Media.maybe_fetch_and_save(me, [url])
  end

  test "a content type's parameters are dropped" do
    me = fake_user!()
    url = "https://files.example.test/download/4822"
    mock_response("application/rtf; charset=utf-8", "{\\rtf1 a report}")

    assert [%Media{media_type: "application/rtf"}] = Media.maybe_fetch_and_save(me, [url])
  end

  test "with no content type, the URL's extension gives the type" do
    me = fake_user!()
    url = "https://files.example.test/papers/report.pdf"
    mock_response(nil, "%PDF-1.4 a report")

    assert [%Media{media_type: "application/pdf"}] = Media.maybe_fetch_and_save(me, [url])
  end

  test "control: a web page is still a link" do
    me = fake_user!()
    url = "https://files.example.test/page"

    mock_response(
      "text/html; charset=utf-8",
      ~s(<html><head><title>A page</title><meta property="og:title" content="A page"></head><body>hi</body></html>)
    )

    assert [%Media{media_type: "link"}] = Media.maybe_fetch_and_save(me, [url])
  end
end
