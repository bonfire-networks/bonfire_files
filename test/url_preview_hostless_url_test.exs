# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.URLPreviewHostlessURLTest do
  @moduledoc """
  A URL with no host (eg. `example.com/foo`, pasted without a scheme) used to crash the URL-preview fetch and take the whole publish down with it: `Unfurl.maybe_favicon/2` handed `nil` to Faviconic, whose `get_absolute_image_path/2` calls `URI.parse/1` → `FunctionClauseError`. The exception escaped `do_maybe_fetch_and_save/3` (which only had a `catch`, no `rescue`), so the user just saw "Could not publish your post".

  Fixed in `forks/unfurl` by passing the url instead of `nil`, and defended here by a `rescue` that degrades to "no preview" in dev/prod while still raising in `:test` (via `Untangle.err/2`).
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend
  import Tesla.Mock

  alias Bonfire.Files.Media

  # a hostless url: `URI.parse/1` gives `%URI{scheme: nil, host: nil}` for this
  @hostless_url "example.com/no-scheme"

  setup do
    # the page must carry a <link rel="icon"> for the favicon path to be reached at all. The href points at an unresolvable host so faviconic's `Req.head` (not Tesla, so not mocked) fails fast and returns nil rather than reaching the network.
    mock_global(fn
      %{method: :get} ->
        %Tesla.Env{
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: """
          <html><head>
            <title>A page with a favicon</title>
            <link rel="icon" href="https://unresolvable.invalid/favicon.ico">
          </head><body>hello</body></html>
          """
        }

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    :ok
  end

  test "fetching a preview for a hostless URL does not raise" do
    me = fake_user!()

    assert [_] = Media.maybe_fetch_and_save(me, [@hostless_url])
  end

  test "publishing a post with a hostless URL still succeeds" do
    me = fake_user!()

    assert {:ok, _post} =
             Bonfire.Posts.publish(
               current_user: me,
               boundary: "public",
               urls: [@hostless_url],
               post_attrs: %{post_content: %{html_body: "Look at #{@hostless_url}"}}
             )
  end
end
