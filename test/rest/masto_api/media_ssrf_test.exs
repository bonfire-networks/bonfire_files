# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.MastoApi.MediaSSRFTest do
  @moduledoc """
  The Mastodon API's `POST /api/v1/media` takes `file` as a multipart upload only. A string used to be accepted too: a URL was downloaded by the server (to any address, including private ones), and anything else was read as a path on the server's own disk. Both are refused now. Uploading a real file is covered in `Bonfire.Files.MastoApi.MediaTest`.
  """
  use Bonfire.Files.MastoApiCase, async: true

  import Bonfire.Files.Simulation
  alias Bonfire.Me.Fake

  @moduletag :masto_api

  setup %{conn: conn} do
    account = Fake.fake_account!()
    user = Fake.fake_user!(account)

    {:ok, api_conn: masto_api_conn(conn, user: user, account: account)}
  end

  test "a URL string is refused rather than downloaded by the server", %{api_conn: api_conn} do
    conn =
      post(api_conn, "/api/v1/media", %{"file" => "http://169.254.169.254/latest/meta-data/"})

    assert conn.status == 422
  end

  test "a path string is refused rather than read from the server's disk", %{
    api_conn: api_conn
  } do
    conn = post(api_conn, "/api/v1/media", %{"file" => image_file().path})

    assert conn.status == 422
  end
end
