# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.UploadGpsMetadataTest do
  @moduledoc """
  Privacy check: no file we store or serve for an upload may keep the location the uploader's device embedded in it (EXIF/XMP GPS in images, QuickTime/MP4 location atoms in videos).

  Uploads go through `Bonfire.Files.upload/5` (as the composer and the profile forms do), then every file stored under the creator's upload directory is read back with `exiftool`, and the raw bytes are searched for the coordinates.

  Fixtures in `test/fixtures/gps/` all embed 48.8584 N, 2.2945 E.
  """
  use Bonfire.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Files

  alias Bonfire.Files.{
    BannerUploader,
    DocumentUploader,
    EmojiUploader,
    IconUploader,
    ImageUploader,
    InstanceIconUploader,
    VideoUploader
  }

  @fixtures Path.expand("fixtures/gps", __DIR__)

  # {fixture, uploader (nil = let Bonfire choose by type), client_name override}
  @cases [
    # ImageUploader (resized to 580x700 via vipsthumbnail/convert/Image, only for jpg/jpeg/png/webp; not gif, not other extensions)
    {"gps.jpg", ImageUploader, nil},
    {"gps.png", ImageUploader, nil},
    {"gps_anim.gif", ImageUploader, nil},
    {"gps.tiff", ImageUploader, nil},
    {"gps.svg", ImageUploader, nil},
    {"gps.webp", ImageUploader, nil},
    {"gps.heic", ImageUploader, nil},
    # the extension comes from the client-supplied name, the type from the bytes
    {"gps.jpg", ImageUploader, "photo.jpe"},
    {"gps.jpg", ImageUploader, "photo"},
    {"gps.jpg", nil, nil},
    # IconUploader
    {"gps.jpg", IconUploader, nil},
    {"gps.png", IconUploader, nil},
    {"gps_anim.gif", IconUploader, nil},
    {"gps_anim.webp", IconUploader, nil},
    {"gps.tiff", IconUploader, nil},
    # BannerUploader
    {"gps.jpg", BannerUploader, nil},
    {"gps.png", BannerUploader, nil},
    {"gps_anim.gif", BannerUploader, nil},
    {"gps.tiff", BannerUploader, nil},
    # InstanceIconUploader
    {"gps.jpg", InstanceIconUploader, nil},
    {"gps.webp", InstanceIconUploader, nil},
    {"gps.tiff", InstanceIconUploader, nil},
    {"gps.svg", InstanceIconUploader, nil},
    # EmojiUploader (`transform(_, _) -> :noaction`)
    {"gps.png", EmojiUploader, nil},
    {"gps.jpg", EmojiUploader, nil},
    {"gps_anim.gif", EmojiUploader, nil},
    {"gps_anim.webp", EmojiUploader, nil},
    {"gps.svg", EmojiUploader, nil},
    # VideoUploader (default version `:noaction`, thumbnail is a new jpg frame)
    {"gps.mp4", VideoUploader, nil},
    {"gps.mp4", nil, nil},
    # DocumentUploader (default version `:noaction`)
    {"gps.pdf", DocumentUploader, nil}
  ]

  @refused_fixtures ["gps.pdf"]
  @stripped_fixtures ["gps.mp4"]

  if System.find_executable("exiftool") do
    for {fixture, uploader, client_name} <- @cases do
      name =
        "#{fixture} via #{(uploader && inspect(uploader)) || "auto-chosen uploader"}" <>
          if(client_name, do: " named #{inspect(client_name)}", else: "")

      test "keeps no GPS in stored or served files: #{name}" do
        creator = fake_user!()
        path = Path.join(unquote(@fixtures), unquote(fixture))
        attrs = if unquote(client_name), do: %{client_name: unquote(client_name)}, else: %{}

        file = %{path: path, filename: unquote(client_name) || unquote(fixture)}

        result = Files.upload(unquote(uploader), creator, file, attrs)

        # a PDF is never stripped: when it carries a location it is refused, not stored
        if unquote(fixture) in @refused_fixtures do
          assert {:error, %Bonfire.Fail{code: :location_metadata, message: message}} = result
          assert message =~ "location"
          assert stored_files(creator) == []
        end

        # an SVG is sanitised (its metadata goes), or refused where the sanitiser isn't compiled in (the case in test unless its dep includes `:test`), as SVG isn't among the accepted types then (the refusal at upload, once SVG is accepted, is tested in `svg_sanitizing_test.exs`)
        if unquote(fixture) == "gps.svg" do
          if Code.ensure_loaded?(SvgSanitizer) do
            assert {:ok, _} = result
          else
            assert {:error, %Bonfire.Fail{code: :file_type_not_allowed}} = result
            assert stored_files(creator) == []
          end
        end

        # an MP4 is stripped by stream copy, so the upload must go through
        if unquote(fixture) in @stripped_fixtures do
          assert {:ok, _} = result
        end

        case result do
          {:ok, upload} ->
            stored = stored_files(creator)
            assert stored != [], "upload succeeded but no file was found on disk for the creator"

            served =
              for version <- [:default, :thumbnail],
                  url = Files.remote_url(nil, upload, version),
                  is_binary(url),
                  do: {version, url}

            leaks = for f <- stored, leak = gps_leak(f), do: {Path.relative_to_cwd(f), leak}

            assert leaks == [],
                   "GPS kept in stored file(s) #{inspect(Enum.map(stored, &Path.relative_to_cwd/1))}; served URLs #{inspect(served)}; leaks: #{inspect(leaks)}"

          {:error, _} ->
            # refused (type not accepted by this uploader): nothing stored, nothing to leak
            assert stored_files(creator) == []
        end
      end
    end
  end

  # the resize tool is picked at runtime by `MediaEdit.choose_executable/2` (first of vipsthumbnail, ImageMagick `convert`, the `Image` library): force each branch in turn
  @tool_branches [
    {"vipsthumbnail only", [{"vipsthumbnail", true}, {"convert", false}, {Image, false}]},
    {"convert only", [{"vipsthumbnail", false}, {"convert", true}, {Image, false}]},
    {"Image library only", [{"vipsthumbnail", false}, {"convert", false}, {Image, true}]}
  ]
  @branch_cases [
    {"gps.jpg", ImageUploader},
    {"gps.png", ImageUploader},
    {"gps.jpg", IconUploader},
    {"gps.webp", IconUploader},
    {"gps.jpg", BannerUploader},
    {"gps.png", InstanceIconUploader}
  ]

  if System.find_executable("exiftool") do
    for {branch, tools} <- @tool_branches, {fixture, uploader} <- @branch_cases do
      test "keeps no GPS with #{branch}: #{fixture} via #{inspect(uploader)}" do
        for {name, val} <- unquote(Macro.escape(tools)),
            do: Process.put([:bonfire_files, :choose_executable, name], val)

        creator = fake_user!()
        path = Path.join(unquote(@fixtures), unquote(fixture))

        assert {:ok, _upload} =
                 Files.upload(unquote(uploader), creator, %{
                   path: path,
                   filename: unquote(fixture)
                 })

        stored = stored_files(creator)
        assert stored != []
        leaks = for f <- stored, leak = gps_leak(f), do: {Path.relative_to_cwd(f), leak}
        assert leaks == [], "GPS kept with #{unquote(branch)}: #{inspect(leaks)}"
      end
    end

    # no resize tool at all: the upload must be refused rather than stored untouched
    test "keeps no GPS with no resize tool at all: refuses or strips" do
      for name <- ["vipsthumbnail", "convert", Image],
          do: Process.put([:bonfire_files, :choose_executable, name], false)

      creator = fake_user!()
      path = Path.join(@fixtures, "gps.jpg")

      case Files.upload(ImageUploader, creator, %{path: path, filename: "gps.jpg"}) do
        {:ok, _} ->
          leaks = for f <- stored_files(creator), leak = gps_leak(f), do: {f, leak}
          assert leaks == [], "stored untouched with no resize tool: #{inspect(leaks)}"

        {:error, _} ->
          assert stored_files(creator) == []
      end
    end
  end

  # what is stored must not carry a location, whichever way it is found: with `exiftool` where present, else by scanning the bytes (as production, which has none)
  for {mode, exiftool} <- [{"with exiftool", nil}, {"by scanning the bytes", false}] do
    describe "refusing a stored file that still has a location, #{mode}" do
      test "an MP4 is refused when ffmpeg is absent (nothing strips it)" do
        put_detection(unquote(exiftool))
        Process.put([:bonfire_files, :choose_executable, "ffmpeg"], false)
        creator = fake_user!()
        path = Path.join(@fixtures, "gps.mp4")

        assert {:error, %Bonfire.Fail{code: :location_metadata, message: message}} =
                 Files.upload(VideoUploader, creator, %{path: path, filename: "gps.mp4"})

        assert message =~ "location"
        assert stored_files(creator) == []
      end

      test "a GIF is refused when gifsicle is absent (nothing strips it)" do
        put_detection(unquote(exiftool))
        Process.put([:bonfire_files, :choose_executable, "gifsicle"], false)
        creator = fake_user!()
        path = Path.join(@fixtures, "gps_anim.gif")

        assert {:error, %Bonfire.Fail{code: :location_metadata}} =
                 Files.upload(ImageUploader, creator, %{path: path, filename: "gps_anim.gif"})

        assert stored_files(creator) == []
      end

      test "a PDF without a location is accepted, even where its text says \"location\"" do
        put_detection(unquote(exiftool))
        creator = fake_user!()
        path = Path.join(@fixtures, "clean.pdf")

        assert {:ok, _} =
                 Files.upload(DocumentUploader, creator, %{path: path, filename: "clean.pdf"})

        assert stored_files(creator) != []
      end

      test "an SVG without a location is accepted where it can be sanitised, else refused as unsanitised" do
        put_detection(unquote(exiftool))
        creator = fake_user!()
        path = Path.join(@fixtures, "clean.svg")

        result = Files.upload(ImageUploader, creator, %{path: path, filename: "clean.svg"})

        if Code.ensure_loaded?(SvgSanitizer) do
          assert {:ok, _} = result
          assert stored_files(creator) != []
        else
          assert {:error, %Bonfire.Fail{code: :file_type_not_allowed}} = result
          assert stored_files(creator) == []
        end
      end
    end
  end

  describe "a video is stripped only when it has a location" do
    test "a clean MP4 is stored as it is, and ffmpeg is not run" do
      marker = spy_on_ffmpeg()
      creator = fake_user!()
      path = Path.join(@fixtures, "clean.mp4")

      assert {:ok, _} = Files.upload(VideoUploader, creator, %{path: path, filename: "clean.mp4"})

      refute ffmpeg_stripped?(marker), "ffmpeg stripped a video with no location"
      original = File.read!(path)
      assert Enum.any?(stored_files(creator), &(File.read!(&1) == original))
    end

    test "an MP4 with a location is stripped by ffmpeg and stored clean" do
      marker = spy_on_ffmpeg()
      creator = fake_user!()
      path = Path.join(@fixtures, "gps.mp4")

      assert {:ok, _} = Files.upload(VideoUploader, creator, %{path: path, filename: "gps.mp4"})

      assert ffmpeg_stripped?(marker), "ffmpeg did not strip a video with a location"
      stored = stored_files(creator)
      assert stored != []
      assert Enum.all?(stored, &is_nil(Bonfire.Files.LocationMetadata.find(&1)))
      refute Enum.any?(stored, &(File.read!(&1) == File.read!(path)))
    end

    test "an MP4 with a location is refused when ffmpeg is absent" do
      Process.put([:bonfire_files, :choose_executable, "ffmpeg"], false)
      creator = fake_user!()
      path = Path.join(@fixtures, "gps.mp4")

      assert {:error, %Bonfire.Fail{code: :location_metadata}} =
               Files.upload(VideoUploader, creator, %{path: path, filename: "gps.mp4"})

      assert stored_files(creator) == []
    end
  end

  # makes `ffmpeg` a script that leaves a marker file when it is run, and returns the marker's path
  defp spy_on_ffmpeg do
    id = System.unique_integer([:positive])
    marker = Path.join(System.tmp_dir!(), "ffmpeg_ran_#{id}")
    script = Path.join(System.tmp_dir!(), "ffmpeg_spy_#{id}.sh")

    File.write!(
      script,
      "#!/bin/sh\necho \"$@\" >> #{marker}\nexec #{System.find_executable("ffmpeg")} \"$@\"\n"
    )

    File.chmod!(script, 0o755)
    on_exit(fn -> File.rm(script) && File.rm(marker) end)
    Process.put([:bonfire_files, :choose_executable, "ffmpeg"], script)
    marker
  end

  # whether `ffmpeg` was run to strip the metadata (it also runs to make the thumbnail)
  defp ffmpeg_stripped?(marker),
    do: File.exists?(marker) and File.read!(marker) =~ "-map_metadata"

  # nil: the tool is used where present; false: forced absent
  defp put_detection(exiftool),
    do: Process.put([:bonfire_files, :choose_executable, "exiftool"], exiftool)

  # every file under the creator's upload directory, whatever its version
  defp stored_files(creator) do
    Path.wildcard("data/uploads/#{creator.id}/**/*")
    |> Enum.filter(&File.regular?/1)
  end

  defp gps_leak(path) do
    {out, _} = System.cmd("exiftool", ["-a", "-G1", "-s", "-ee", path], stderr_to_stdout: true)

    tags =
      out
      |> String.split("\n", trim: true)
      # the `System` group has the file's own name, whose random id can spell "GPS"
      |> Enum.reject(&String.starts_with?(&1, "[System]"))
      |> Enum.filter(&(&1 =~ ~r/GPS|Location|Coordinates/i))

    bin = File.read!(path)

    raw =
      Enum.filter(
        ["48.8584", "48,51.504", "+48.8584+002.2945"],
        &String.contains?(bin, &1)
      )

    if tags == [] and raw == [], do: nil, else: %{tags: tags, raw: raw}
  end
end
