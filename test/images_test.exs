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
        _w =
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

    yes? = ~w(true yes 1)

    if System.get_env("CI") not in yes? do
      test "strips metadata when vipsthumbnail is available" do
        # Force vipsthumbnail present and others absent to test this code path
        Process.put([:bonfire_files, :choose_executable, "vipsthumbnail"], true)
        Process.put([:bonfire_files, :choose_executable, "convert"], false)
        Process.put([:bonfire_files, :choose_executable, Image], false)

        assert Bonfire.Files.MediaEdit.choose_executable(:image, "vipsthumbnail") =~
                 "vipsthumbnail"

        refute Bonfire.Files.MediaEdit.choose_executable(:image, "convert")
        refute Bonfire.Files.MediaEdit.choose_executable(:image, Image)

        try do
          assert {:ok, upload} = fake_upload(image_with_exif_file(), ImageUploader)

          path =
            Files.local_path(ImageUploader, upload) ||
              ImageUploader.remote_url(upload) |> String.trim_leading("/")

          bin = File.read!(path)
          refute bin =~ "Exif\0\0"
        after
          Process.delete([:bonfire_files, :choose_executable, Image])
          Process.delete([:bonfire_files, :choose_executable, "vipsthumbnail"])
          Process.delete([:bonfire_files, :choose_executable, "convert"])
        end
      end

      test "strips metadata when convert (ImageMagick) is available" do
        # Force convert present and vipsthumbnail absent to test this code path
        Process.put([:bonfire_files, :choose_executable, "convert"], true)
        Process.put([:bonfire_files, :choose_executable, "vipsthumbnail"], false)
        Process.put([:bonfire_files, :choose_executable, Image], false)

        assert Bonfire.Files.MediaEdit.choose_executable(:image, "convert") =~ "convert"
        refute Bonfire.Files.MediaEdit.choose_executable(:image, "vipsthumbnail")
        refute Bonfire.Files.MediaEdit.choose_executable(:image, Image)

        try do
          assert {:ok, upload} = fake_upload(image_with_exif_file(), ImageUploader)

          path =
            Files.local_path(ImageUploader, upload) ||
              ImageUploader.remote_url(upload) |> String.trim_leading("/")

          bin = File.read!(path)
          refute bin =~ "Exif\0\0"
        after
          Process.delete([:bonfire_files, :choose_executable, "convert"])
          Process.delete([:bonfire_files, :choose_executable, "vipsthumbnail"])
          Process.delete([:bonfire_files, :choose_executable, Image])
        end
      end

      test "strips some metadata when Image library is available" do
        # Force all external tools absent to test Image library fallback
        Process.put([:bonfire_files, :choose_executable, Image], true)
        Process.put([:bonfire_files, :choose_executable, "convert"], false)
        Process.put([:bonfire_files, :choose_executable, "vipsthumbnail"], false)

        # tell it to strip all metadata (not keeping authorship, copyright, etc) for this test 
        Process.put([:bonfire_files, :strip_author_metadata], false)

        assert Bonfire.Files.MediaEdit.choose_executable(:image, Image) == Image
        refute Bonfire.Files.MediaEdit.choose_executable(:image, "vipsthumbnail")
        refute Bonfire.Files.MediaEdit.choose_executable(:image, "convert")

        try do
          {:ok, image} = Image.open(image_with_exif_file().path)

          assert {:ok, exif_before} =
                   Image.exif(image)
                   |> debug("exif")

          assert e(exif_before, :make, nil) == "Sample Generator"
          assert e(exif_before, :software, nil) == "JPEG factory"
          assert e(exif_before, :artist, nil) == "JPEG artist"
          assert e(exif_before, :copyright, nil) =~ "public domain"

          assert {:ok, upload} =
                   fake_upload(image_with_exif_file(), ImageUploader)
                   |> debug("uploaded")

          path =
            Files.local_path(ImageUploader, upload) ||
              ImageUploader.remote_url(upload) |> String.trim_leading("/")

          # bin = File.read!(path)
          # refute bin =~ "Exif\0\0"

          {:ok, image} = Image.open(path)

          assert {:ok, exif_after} =
                   Image.exif(image)
                   |> debug("exif after")

          refute exif_before == exif_after
          refute e(exif_after, :make, nil) == "Sample Generator"
          refute e(exif_after, :software, nil) == "JPEG factory"

          # these are preserved
          assert e(exif_after, :artist, nil) == "JPEG artist"
          assert e(exif_after, :copyright, nil) =~ "public domain"
        after
          Process.delete([:bonfire_files, :choose_executable, Image])
          Process.delete([:bonfire_files, :choose_executable, "vipsthumbnail"])
          Process.delete([:bonfire_files, :choose_executable, "convert"])
          Process.delete([:bonfire_files, :strip_author_metadata])
        end
      end

      test "can strips author metadata when Image library is available" do
        # Force all external tools absent to test Image library fallback
        Process.put([:bonfire_files, :choose_executable, Image], true)
        Process.put([:bonfire_files, :choose_executable, "convert"], false)
        Process.put([:bonfire_files, :choose_executable, "vipsthumbnail"], false)

        # tell it to strip all metadata (not keeping authorship, copyright, etc) for this test 
        Process.put([:bonfire_files, :strip_author_metadata], true)

        assert Bonfire.Files.MediaEdit.choose_executable(:image, Image) == Image
        refute Bonfire.Files.MediaEdit.choose_executable(:image, "vipsthumbnail")
        refute Bonfire.Files.MediaEdit.choose_executable(:image, "convert")

        try do
          {:ok, image} = Image.open(image_with_exif_file().path)

          assert {:ok, exif_before} =
                   Image.exif(image)
                   |> debug("exif")

          assert e(exif_before, :make, nil) == "Sample Generator"
          assert e(exif_before, :software, nil) == "JPEG factory"
          assert e(exif_before, :artist, nil) == "JPEG artist"
          assert e(exif_before, :copyright, nil) =~ "public domain"

          assert {:ok, upload} =
                   fake_upload(image_with_exif_file(), ImageUploader)
                   |> debug("uploaded")

          path =
            Files.local_path(ImageUploader, upload) ||
              ImageUploader.remote_url(upload) |> String.trim_leading("/")

          # bin = File.read!(path)
          # refute bin =~ "Exif\0\0"

          {:ok, image} = Image.open(path)

          assert {:ok, exif_after} =
                   Image.exif(image)
                   |> debug("exif after")

          refute exif_before == exif_after
          refute e(exif_after, :make, nil) == "Sample Generator"
          refute e(exif_after, :software, nil) == "JPEG factory"
          refute e(exif_after, :artist, nil) == "JPEG artist"
          refute e(exif_after, :copyright, nil)
        after
          Process.delete([:bonfire_files, :choose_executable, Image])
          Process.delete([:bonfire_files, :choose_executable, "vipsthumbnail"])
          Process.delete([:bonfire_files, :choose_executable, "convert"])
          Process.delete([:bonfire_files, :strip_author_metadata])
        end
      end

      test "refuses to upload when no external tool is available to strip metadata" do
        # Force all external tools absent
        Process.put([:bonfire_files, :choose_executable, "vipsthumbnail"], false)
        Process.put([:bonfire_files, :choose_executable, "convert"], false)
        Process.put([:bonfire_files, :choose_executable, Image], false)

        refute Bonfire.Files.MediaEdit.choose_executable(:image, Image)
        refute Bonfire.Files.MediaEdit.choose_executable(:image, "vipsthumbnail")
        refute Bonfire.Files.MediaEdit.choose_executable(:image, "convert")

        try do
          bin = File.read!(image_with_exif_file().path)
          assert bin =~ "Exif\0\0"

          assert {:error, error} = fake_upload(image_with_exif_file(), ImageUploader)
          assert inspect(error) =~ "No image processing tool available"
        after
          Process.delete([:bonfire_files, :choose_executable, "vipsthumbnail"])
          Process.delete([:bonfire_files, :choose_executable, "convert"])
          Process.delete([:bonfire_files, :choose_executable, Image])
        end
      end
    end
  end
end
