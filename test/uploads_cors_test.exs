# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.UploadsCORSTest do
  @moduledoc """
  Mastodon client apps that run in a browser (Phanpy, Elk) load avatars and media from the instance cross-origin, and some of them ask for the image with `crossorigin="anonymous"` (Phanpy's boosts carousel does). The browser then shows the image only if every hop answers with `Access-Control-Allow-Origin`: the `/files/redir/...` redirect and the `/data/uploads/...` file it points to.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  @endpoint Application.compile_env!(:bonfire, :endpoint_module)

  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader

  @client_origin "https://phanpy.social"

  defp upload!(user, filename, content) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{filename}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)

    {:ok, media} = Files.upload(ImageUploader, user, %{path: path, filename: filename})
    local = Files.local_path(ImageUploader, media)
    assert local && File.exists?(local)
    on_exit(fn -> File.rm(local) end)

    "/" <> Path.relative_to_cwd(local)
  end

  defp from_client_app, do: build_conn() |> put_req_header("origin", @client_origin)

  defp assert_cors_allowed(conn) do
    assert [allowed] = get_resp_header(conn, "access-control-allow-origin")
    assert allowed in ["*", @client_origin]
  end

  setup do
    path =
      upload!(fake_user!(), "icon.png", File.read!(Bonfire.Files.Simulation.icon_file().path))

    {:ok, path: path}
  end

  test "the /files/redir redirect answers a client app's origin", %{path: path} do
    served = get(from_client_app(), "/files/redir/local" <> path)

    assert served.status in [301, 302]
    assert_cors_allowed(served)
  end

  test "the uploaded file it redirects to answers a client app's origin", %{path: path} do
    served = get(from_client_app(), path)

    assert served.status == 200
    assert_cors_allowed(served)
  end
end
