# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.UploadsCSPTest do
  @moduledoc """
  Files under `/data/uploads/` are served from the instance's own origin, and image uploads accept SVG, which can carry scripts. Every upload is served with a sandboxing Content-Security-Policy, so opening one directly can't run script with the instance's cookies, while images, video and audio still display inside pages.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]
  @endpoint Application.compile_env!(:bonfire, :endpoint_module)

  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader

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

  test "an uploaded SVG is served sandboxed, so its scripts can't run" do
    svg =
      ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(document.cookie)</script></svg>|

    path = upload!(fake_user!(), "avatar.svg", svg)

    served = get(build_conn(), path)

    assert served.status == 200
    assert ["image/svg+xml" <> _] = get_resp_header(served, "content-type")
    assert [csp] = get_resp_header(served, "content-security-policy")
    assert csp =~ "sandbox"
  end

  test "an uploaded PNG is still served as an image" do
    path =
      upload!(fake_user!(), "icon.png", File.read!(Bonfire.Files.Simulation.icon_file().path))

    served = get(build_conn(), path)

    assert served.status == 200
    assert ["image/png" <> _] = get_resp_header(served, "content-type")
  end
end
