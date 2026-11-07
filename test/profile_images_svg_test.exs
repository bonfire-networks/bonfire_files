# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ProfileImagesSvgTest do
  @moduledoc "Avatars and banners refuse SVG: we can't make a raster copy of one, and other fediverse apps (eg. Mastodon) don't show an SVG avatar or banner. Post images still accept SVG."
  use Bonfire.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Files
  alias Bonfire.Files.IconUploader
  alias Bonfire.Files.BannerUploader
  alias Bonfire.Files.ImageUploader
  alias Bonfire.Files.Simulation

  @svg ~s|<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>|

  defp svg_file do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-avatar.svg")
    File.write!(path, @svg)
    on_exit(fn -> File.rm(path) end)
    %{path: path, filename: "avatar.svg"}
  end

  for uploader <- [IconUploader, BannerUploader] do
    test "#{inspect(uploader)} accepts a PNG" do
      assert {:ok, _media} =
               Files.upload(unquote(uploader), fake_user!(), Simulation.icon_file())
    end

    test "#{inspect(uploader)} refuses an SVG" do
      assert {:error, _} = Files.upload(unquote(uploader), fake_user!(), svg_file())
    end
  end

  test "ImageUploader still accepts an SVG" do
    assert {:ok, _media} = Files.upload(ImageUploader, fake_user!(), svg_file())
  end
end
