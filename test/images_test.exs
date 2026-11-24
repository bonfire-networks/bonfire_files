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
  alias Bonfire.Files.InstanceIconUploader
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

    test "keeps instance icons large enough for high-density displays" do
      assert {:ok, upload} = fake_upload(image_file(), InstanceIconUploader)
      icon_path = Files.local_path(InstanceIconUploader, upload)

      # the size only holds where an image toolchain exists: `dimensions/1` reads the header with `Image`, and with no resize tool at all the upload is stored untransformed
      if Bonfire.Files.MediaEdit.choose_executable(:dimensions, Image) do
        assert {512, 512} == Bonfire.Files.MediaEdit.dimensions(icon_path)
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
        vipsthumbnail = System.find_executable("vipsthumbnail")

        # Force vipsthumbnail present and others absent to test this code path
        Process.put([:bonfire_files, :choose_executable, "vipsthumbnail"], vipsthumbnail || false)
        Process.put([:bonfire_files, :choose_executable, "convert"], false)
        Process.put([:bonfire_files, :choose_executable, Image], false)

        try do
          if vipsthumbnail do
            assert Bonfire.Files.MediaEdit.choose_executable(:image, "vipsthumbnail") =~
                     "vipsthumbnail"

            refute Bonfire.Files.MediaEdit.choose_executable(:image, "convert")
            refute Bonfire.Files.MediaEdit.choose_executable(:image, Image)

            assert {:ok, upload} = fake_upload(image_with_exif_file(), ImageUploader)

            path =
              Files.local_path(ImageUploader, upload) ||
                ImageUploader.remote_url(upload) |> String.trim_leading("/")

            bin = File.read!(path)
            refute bin =~ "Exif\0\0"
          end
        after
          Process.delete([:bonfire_files, :choose_executable, Image])
          Process.delete([:bonfire_files, :choose_executable, "vipsthumbnail"])
          Process.delete([:bonfire_files, :choose_executable, "convert"])
        end
      end

      # the size is a maximum: a smaller image is stored at its own size, not scaled up to it (as with `convert`'s `>` and `Image`'s `resize: :down`)
      test "keeps a small image at its own size when vipsthumbnail is available" do
        vipsthumbnail = System.find_executable("vipsthumbnail")

        Process.put([:bonfire_files, :choose_executable, "vipsthumbnail"], vipsthumbnail || false)
        Process.put([:bonfire_files, :choose_executable, "convert"], false)
        Process.put([:bonfire_files, :choose_executable, Image], false)

        try do
          if vipsthumbnail do
            assert "150x150" == geometry(icon_file().path), "control: the fixture is 150x150"
            assert {:ok, upload} = fake_upload(icon_file(), ImageUploader)

            path =
              Files.local_path(ImageUploader, upload) ||
                ImageUploader.remote_url(upload) |> String.trim_leading("/")

            assert "150x150" == geometry(path)
          end
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

          exif_after =
            case Image.exif(image) |> debug("exif after") do
              {:ok, exif} -> exif
              # an image stripped of everything carries no EXIF block at all, so there is nothing left to read
              {:error, _no_exif} -> %{}
            end

          refute exif_before == exif_after
          refute e(exif_after, :make, nil)
          refute e(exif_after, :software, nil)
          refute e(exif_after, :artist, nil)
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

  # each size is a maximum, whichever tool the server has: a smaller file keeps its size, not scaled up to it. Each tool's command runs as Waffle runs it (`tool input args output`)
  describe "a small file isn't scaled up" do
    @tools ["vipsthumbnail", "convert", "ffmpeg", "ffmpegthumbnailer"]

    setup do
      on_exit(fn ->
        for tool <- @tools, do: Process.delete([:bonfire_files, :choose_executable, tool])
      end)

      :ok
    end

    for tool <- ["vipsthumbnail", "convert"] do
      @tool tool

      test "#{tool}: an avatar smaller than its size keeps its size, and a bigger one is still cropped down" do
        if only(@tool) do
          assert "150x150" ==
                   run_tool(
                     Bonfire.Files.MediaEdit.thumbnail("a.png", 1000),
                     icon_file().path,
                     "png"
                   )

          assert "142x142" ==
                   run_tool(
                     Bonfire.Files.MediaEdit.thumbnail("a.png", 142),
                     image_file().path,
                     "png"
                   )
        end
      end

      test "#{tool}: a banner smaller than its size isn't scaled up, and a bigger one is still cropped to 3:1" do
        if only(@tool) do
          [w, h] =
            run_tool(Bonfire.Files.MediaEdit.banner("a.png", 3000, 1000), icon_file().path, "png")
            |> sizes()

          assert w <= 150 and h <= 150

          assert "300x100" ==
                   run_tool(
                     Bonfire.Files.MediaEdit.banner("a.png", 300, 100),
                     image_file().path,
                     "png"
                   )
        end
      end
    end

    for tool <- ["ffmpeg", "ffmpegthumbnailer"] do
      @tool tool

      test "#{tool}: a video's poster frame isn't scaled up past the video's size, and a bigger one is still scaled down" do
        if only(@tool) do
          # `WxH`, as `VideoUploader` gives it; the video is 640x360
          assert "640x360" ==
                   run_tool(
                     Bonfire.Files.MediaEdit.thumbnail_video("a.mp4", "1000x1000", percent: 10),
                     video_file().path,
                     "jpg"
                   )

          assert "320x180" ==
                   run_tool(
                     Bonfire.Files.MediaEdit.thumbnail_video("a.mp4", "320x320", percent: 10),
                     video_file().path,
                     "jpg"
                   )
        end
      end
    end

    # makes `tool` the only one `MediaEdit` finds, if it's installed
    defp only(tool) do
      for other <- @tools,
          other != tool,
          do: Process.put([:bonfire_files, :choose_executable, other], false)

      path = System.find_executable(tool)
      if path, do: Process.put([:bonfire_files, :choose_executable, tool], path)
      path
    end

    defp run_tool(transformation, input, ext) do
      output =
        Path.join(System.tmp_dir!(), "media_edit_#{System.unique_integer([:positive])}.#{ext}")

      case transformation do
        # a function transformation runs its tools itself, and gives the file it made
        {transform, _ext} when is_function(transform, 2) ->
          {:ok, %{path: made}} =
            transform.(:default, %Waffle.File{path: input, file_name: Path.basename(input)})

          geometry(made)

        transformation ->
          {tool, args} =
            case transformation do
              {tool, args, _ext} when is_function(args) -> {tool, args.(input, output)}
              {tool, args} when is_function(args) -> {tool, args.(input, output)}
              {tool, args} -> {tool, [input | String.split(args, " ")] ++ [output]}
            end

          {_, 0} =
            System.cmd(System.find_executable(to_string(tool)), args, stderr_to_stdout: true)

          geometry(output)
      end
    end

    defp sizes(geometry), do: geometry |> String.split("x") |> Enum.map(&String.to_integer/1)
  end
end
