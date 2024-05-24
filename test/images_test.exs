# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ImagesTest do
  use Bonfire.DataCase, async: true
  @moduletag :backend

  import Bonfire.Files.Simulation

  alias Bonfire.Common.Simulation
  alias Bonfire.Files

  alias Bonfire.Files.DocumentUploader
  alias Bonfire.Files.FileDenied
  alias Bonfire.Files.IconUploader
  alias Bonfire.Files.ImageUploader
  alias Bonfire.Files.Media

  describe "upload" do
    test "creates transformed versions for icons" do
      assert {:ok, upload} = fake_upload(icon_file(), IconUploader)

      if !System.get_env("CI") do
        # resized version(s)
        assert "142x142" ==
                 IconUploader.remote_url(upload)
                 # String.slice(1, 10000)
                 |> String.trim_leading("/")
                 |> geometry()

        # assert "48x48" == IconUploader.remote_url(upload, :small) |> String.slice(1, 10000) |> geometry()

        # original file untouched # TODO?
        # assert "150x150" == IconUploader.remote_url(upload, :original) |> String.slice(1, 10000) |> geometry()
      end
    end

    test "creates a transformed version for images" do
      assert {:ok, upload} = fake_upload(image_file(), ImageUploader)

      if !System.get_env("CI") do
        w =
          Bonfire.Common.Config.get_ext(
            :bonfire_files,
            [__MODULE__, :max_width],
            580
          )

        h =
          Bonfire.Common.Config.get_ext(
            :bonfire_files,
            [__MODULE__, :max_height],
            700
          )

        # resized version
        assert "525x#{h}" ==
                 ImageUploader.remote_url(upload)
                 # String.slice(1, 10000)
                 |> String.trim_leading("/")
                 |> geometry()

        # original file untouched # TODO?
        # assert "600x800" == ImageUploader.remote_url(upload, :original) |> String.slice(1, 10000) |> geometry()
      end
    end

    test "creates thumbnail for PDF" do
      assert {:ok, upload} = fake_upload(pdf_file(), DocumentUploader)

      if !System.get_env("CI") do
        # resized version(s)
        thumb = IconUploader.remote_url(upload, :thumbnail)
        assert thumb =~ ".png"

        # assert "595x842" ==
        assert thumb
               # String.slice(1, 10000)
               |> String.trim_leading("/")
               |> geometry()

        # original file untouched # TODO?
        assert IconUploader.remote_url(upload, :default) =~ ".pdf"
      end
    end
  end
end
