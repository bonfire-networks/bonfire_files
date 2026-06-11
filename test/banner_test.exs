# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.BannerTest do
  # not async: these tests mutate global image-sizing config
  use Bonfire.DataCase, async: false
  @moduletag :backend

  import Bonfire.Files.Simulation

  alias Bonfire.Common.Config
  alias Bonfire.Files.BannerUploader
  alias Bonfire.Files.IconUploader
  alias Bonfire.Files.MediaEdit

  describe "banner resizing" do
    test "defaults to a 1500x500 (true 3:1) max size" do
      assert BannerUploader.max_width() == 1500
      assert BannerUploader.max_height() == 500
    end

    test "re-encodes resized images at quality 90 by default" do
      assert MediaEdit.image_quality() == 90
    end

    yes? = ~w(true yes 1)

    if System.get_env("CI") not in yes? do
      test "crops an uploaded banner to a 3:1 ratio within the max bounds" do
        assert {:ok, upload} = fake_upload(image_file(), BannerUploader)

        {w, h} =
          BannerUploader.remote_url(upload)
          |> String.trim_leading("/")
          |> geometry()
          |> parse_geometry()

        # cropped to the hero's 3:1 ratio (regardless of which resize tool ran)...
        assert_in_delta w / h, 3.0, 0.05
        # ...and never enlarged past the configured 1500x500 cap
        assert w <= 1500
        assert h <= 500
      end

      test "avatar/icon size is decoupled from the banner setting" do
        # raising the banner height must NOT bleed into icon/avatar resizing
        original = Config.get([Bonfire.Files, :max_sizes, :banner, :height])
        Config.put([Bonfire.Files, :max_sizes, :banner, :height], 999)
        on_exit(fn -> Config.put([Bonfire.Files, :max_sizes, :banner, :height], original) end)

        assert {:ok, upload} = fake_upload(icon_file(), IconUploader)

        assert {142, 142} ==
                 IconUploader.remote_url(upload)
                 |> String.trim_leading("/")
                 |> geometry()
                 |> parse_geometry()
      end
    end
  end

  defp parse_geometry(geometry) do
    [w, h] = geometry |> String.split("x") |> Enum.map(&String.to_integer/1)
    {w, h}
  end
end
