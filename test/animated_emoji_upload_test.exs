# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.AnimatedEmojiUploadTest do
  @moduledoc """
  Animated GIF/WebP uploads and custom emoji are stripped of their metadata (GPS included) and resized, and keep every animation frame, on each resize tool branch (`MediaEdit.choose_executable/2`).

  Fixtures in `test/fixtures/gps/` are 100x100 and embed 48.8584 N, 2.2945 E; the animated ones have 2 frames.
  """
  use Bonfire.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Files
  alias Bonfire.Files.{EmojiUploader, ImageUploader}

  @fixtures Path.expand("fixtures/gps", __DIR__)
  @apng_fixtures Path.expand("fixtures/apng", __DIR__)
  @emoji_size 48

  # the lossless strippers are off, so the re-encode path runs even for a GIF/WebP that is small enough
  @no_strippers [{"gifsicle", false}, {"webpmux", false}]
  @tool_branches [
    {"vipsthumbnail",
     [{"vipsthumbnail", true}, {"convert", false}, {Image, false}] ++ @no_strippers},
    {"convert", [{"vipsthumbnail", false}, {"convert", true}, {Image, false}] ++ @no_strippers},
    {"Image library",
     [{"vipsthumbnail", false}, {"convert", false}, {Image, true}] ++ @no_strippers}
  ]
  # the `Image` library stays, as it also reads the size that decides whether an emoji needs resizing
  @no_resizers [{"vipsthumbnail", false}, {"convert", false}]

  if System.find_executable("exiftool") do
    for {branch, tools} <- @tool_branches do
      # animated: frames kept, no GPS
      for {fixture, ext} <- [{"gps_anim.gif", ".gif"}, {"gps_anim.webp", ".webp"}] do
        test "keeps the frames and no GPS of a too big emoji with #{branch}: #{fixture}" do
          use_tools(unquote(Macro.escape(tools)))
          Process.put([:bonfire_files, EmojiUploader, :max_size], @emoji_size)
          creator = fake_user!()
          upload!(creator, EmojiUploader, unquote(fixture))

          [stored] = stored_files(creator)
          assert Path.extname(stored) == unquote(ext)
          assert {_w, _h, frames} = image_info(stored)
          assert frames == 2, "expected the 2 frames of the input, got #{frames}"
          assert gps_leak(stored) == nil
        end
      end

      # emoji are small, whatever the format
      for fixture <- ["gps.jpg", "gps.png", "gps_anim.gif", "gps_anim.webp"] do
        test "shrinks an emoji and keeps no GPS with #{branch}: #{fixture}" do
          use_tools(unquote(Macro.escape(tools)))
          Process.put([:bonfire_files, EmojiUploader, :max_size], @emoji_size)
          creator = fake_user!()
          upload!(creator, EmojiUploader, unquote(fixture))

          [stored] = stored_files(creator)
          assert {w, h, _frames} = image_info(stored)
          assert w <= @emoji_size and h <= @emoji_size, "emoji stored at #{w}x#{h}"
          assert w == @emoji_size or h == @emoji_size, "emoji shrunk too far: #{w}x#{h}"
          assert gps_leak(stored) == nil
        end
      end

      # the type comes from the bytes: a JPEG with another name is still resized and stripped, and stored under the extension of its type
      for client_name <- ["photo.jpe", "photo.jfif", "photo"] do
        test "a JPEG named #{inspect(client_name)} is stripped with #{branch}" do
          use_tools(unquote(Macro.escape(tools)))
          creator = fake_user!()
          path = Path.join(@fixtures, "gps.jpg")

          assert {:ok, _} =
                   Files.upload(
                     ImageUploader,
                     creator,
                     %{path: path, filename: unquote(client_name)},
                     %{client_name: unquote(client_name)}
                   )

          [stored] = stored_files(creator)
          assert Path.extname(stored) == ".jpg"
          assert {622, 700, 1} = image_info(stored)
          assert gps_leak(stored) == nil
        end
      end

      # control: a static JPEG through ImageUploader behaves as before (resized to the box, stripped)
      test "static JPEG via ImageUploader is unchanged with #{branch}" do
        use_tools(unquote(Macro.escape(tools)))
        creator = fake_user!()
        upload!(creator, ImageUploader, "gps.jpg")

        [stored] = stored_files(creator)
        assert Path.extname(stored) == ".jpg"
        # the 800x900 fixture, fitted into the 580x700 box
        assert {622, 700, 1} = image_info(stored)
        assert gps_leak(stored) == nil
      end
    end

    # small enough: stripped without re-encoding, so the stored bytes are what `webpmux` gives
    if System.find_executable("webpmux") do
      test "an animated WebP emoji that fits is stripped with webpmux, frames kept" do
        use_tools([{"webpmux", true}] ++ @no_resizers)
        creator = fake_user!()
        upload!(creator, EmojiUploader, "gps_anim.webp")

        tmp = Path.join(System.tmp_dir!(), "webpmux_#{System.unique_integer([:positive])}")
        File.mkdir_p!(tmp)
        input = Path.join(@fixtures, "gps_anim.webp")
        {_, 0} = System.cmd("webpmux", ["-strip", "exif", "-o", "#{tmp}/a.webp", input])
        {_, 0} = System.cmd("webpmux", ["-strip", "xmp", "-o", "#{tmp}/b.webp", "#{tmp}/a.webp"])

        [stored] = stored_files(creator)
        assert File.read!(stored) == File.read!("#{tmp}/b.webp")
        assert {100, 100, 2} = image_info(stored)
        assert gps_leak(stored) == nil
      end
    end

    # skipped where `gifsicle` isn't installed
    if System.find_executable("gifsicle") do
      for uploader <- [ImageUploader, EmojiUploader] do
        test "an animated GIF that fits is stripped with gifsicle, frames and loop kept: #{inspect(uploader)}" do
          use_tools([{"gifsicle", true}] ++ @no_resizers)
          creator = fake_user!()

          # the fixture doesn't loop: make a copy that loops 3 times
          looping =
            Path.join(System.tmp_dir!(), "looping_#{System.unique_integer([:positive])}.gif")

          {_, 0} =
            System.cmd("gifsicle", [
              "--loopcount=3",
              Path.join(@fixtures, "gps_anim.gif"),
              "-o",
              looping
            ])

          assert {:ok, _} =
                   Files.upload(unquote(uploader), creator, %{
                     path: looping,
                     filename: "looping.gif"
                   })

          stripped = looping <> ".stripped"

          {_, 0} =
            System.cmd("gifsicle", [
              "--no-comments",
              "--no-names",
              "--no-extensions",
              looping,
              "-o",
              stripped
            ])

          [stored] = stored_files(creator)
          # not re-encoded: what `gifsicle` gives
          assert File.read!(stored) == File.read!(stripped)
          assert {100, 100, 2} = image_info(stored)
          assert {:ok, _} = loop(looping)
          assert loop(stored) == loop(looping)
          assert gps_leak(stored) == nil
        end
      end
    end

    # no stripper (and a resizer that must not be used for these): the file would be stored as it is, with its location, so it is refused
    for {fixture, uploader} <- [
          {"gps_anim.gif", ImageUploader},
          {"gps_anim.gif", EmojiUploader},
          {"gps_anim.webp", EmojiUploader},
          {"gps.jpg", EmojiUploader},
          {"gps.png", EmojiUploader}
        ] do
      test "is refused without gifsicle/webpmux when no resize is needed: #{fixture} via #{inspect(uploader)}" do
        use_tools(@no_strippers ++ [{"vipsthumbnail", true}])
        # big enough for every fixture to fit
        Process.put([:bonfire_files, EmojiUploader, :max_size], 1000)
        creator = fake_user!()
        path = Path.join(@fixtures, unquote(fixture))

        assert {:error, %Bonfire.Fail{code: :location_metadata}} =
                 Files.upload(unquote(uploader), creator, %{
                   path: path,
                   filename: unquote(fixture)
                 })

        assert stored_files(creator) == []
      end
    end

    # where the sanitiser isn't compiled in (the case in test unless its dep includes `:test`), SVG isn't an accepted type, so it is refused as a file type; where it is, the SVG's metadata is removed and the upload goes through
    test "SVG emoji with a location is refused, or sanitised of it" do
      creator = fake_user!()
      path = Path.join(@fixtures, "gps.svg")

      result = Files.upload(EmojiUploader, creator, %{path: path, filename: "gps.svg"})

      if Code.ensure_loaded?(SvgSanitizer) do
        assert {:ok, _} = result
        refute Enum.any?(stored_files(creator), &(File.read!(&1) =~ "GPSLatitude"))
      else
        assert {:error, %Bonfire.Fail{code: :file_type_not_allowed}} = result
        assert stored_files(creator) == []
      end
    end
  end

  # APNG: `anim_256.png` (256x256) is too big for an emoji, `anim_64.png` fits; both have 5 frames and loop forever. No tool here writes an APNG, so one that would need resizing is refused rather than flattened to its first frame; one that fits is stored as it is
  for {branch, tools} <- @tool_branches do
    test "refuses a too big APNG emoji, storing nothing, with #{branch}" do
      use_tools(unquote(Macro.escape(tools)))
      creator = fake_user!()
      path = Path.join(@apng_fixtures, "anim_256.png")

      assert {:error, %Bonfire.Fail{code: :apng_too_big, message: message}} =
               Files.upload(EmojiUploader, creator, %{path: path, filename: "anim_256.png"})

      assert message =~ "smaller animated image"
      assert message =~ "128x128"
      assert stored_files(creator) == []
    end

    # control: a still PNG of the same size is still shrunk to the emoji size (the still is made with the `Image` library, so it needs it compiled in)
    if Code.ensure_loaded?(Image) do
      test "still shrinks a static PNG of the size of the too big APNG emoji with #{branch}" do
        use_tools(unquote(Macro.escape(tools)))
        creator = fake_user!()
        path = static_png_copy!("anim_256.png", 256)

        assert {:ok, _} =
                 Files.upload(EmojiUploader, creator, %{path: path, filename: "still_256.png"})

        [stored] = stored_files(creator)
        info = apng_info(stored)
        assert info.frames == 1
        assert info.width <= 128 and info.height <= 128
        assert info.width == 128 or info.height == 128
      end
    end
  end

  # no resize happens, so the tool branch doesn't matter
  test "leaves an APNG emoji that fits as it is" do
    creator = fake_user!()
    upload = upload_apng!(creator, "anim_64.png")

    [stored] = stored_files(creator)
    info = apng_info(stored)
    detail = "detected #{inspect(upload.media_type)}, stored #{inspect(info)}"

    assert info == %{width: 64, height: 64, frames: 5, plays: 0}, detail
    assert File.read!(stored) == File.read!(Path.join(@apng_fixtures, "anim_64.png"))
  end

  # the size is read from the PNG header, so it doesn't depend on the `Image` library or on any resize tool
  test "leaves an APNG emoji that fits as it is with the Image library and every tool off" do
    use_tools([{Image, false}, {"vipsthumbnail", false}, {"convert", false}] ++ @no_strippers)
    creator = fake_user!()
    upload_apng!(creator, "anim_64.png")

    [stored] = stored_files(creator)
    assert apng_info(stored) == %{width: 64, height: 64, frames: 5, plays: 0}
    assert File.read!(stored) == File.read!(Path.join(@apng_fixtures, "anim_64.png"))
  end

  # `gps_anim_64.png`: `anim_64.png` with an `eXIf` chunk holding 48.8584 N, 2.2945 E
  test "refuses an APNG emoji that fits but carries a location" do
    creator = fake_user!()
    path = Path.join(@apng_fixtures, "gps_anim_64.png")

    assert {:error, %Bonfire.Fail{code: :location_metadata, message: message}} =
             Files.upload(EmojiUploader, creator, %{path: path, filename: "gps_anim_64.png"})

    assert message =~ "location"
    assert stored_files(creator) == []
  end

  describe "an APNG posted as an image" do
    test "is refused when bigger than the box, storing nothing" do
      Process.put([:bonfire_files, ImageUploader, :max_width], 100)
      Process.put([:bonfire_files, ImageUploader, :max_height], 100)
      creator = fake_user!()
      path = Path.join(@apng_fixtures, "anim_256.png")

      assert {:error, %Bonfire.Fail{code: :apng_too_big, message: message}} =
               Files.upload(ImageUploader, creator, %{path: path, filename: "anim_256.png"})

      assert message =~ "100x100"
      assert stored_files(creator) == []
    end

    test "is stored as it is when within the box (580x700 by default)" do
      creator = fake_user!()
      path = Path.join(@apng_fixtures, "anim_256.png")

      assert {:ok, _} =
               Files.upload(ImageUploader, creator, %{path: path, filename: "anim_256.png"})

      [stored] = stored_files(creator)
      assert File.read!(stored) == File.read!(path)
      assert apng_info(stored).frames == 5
    end

    # control: a still PNG of the same size is still resized
    if Code.ensure_loaded?(Image) do
      test "a static PNG of the same size is still resized to the box" do
        Process.put([:bonfire_files, ImageUploader, :max_width], 100)
        Process.put([:bonfire_files, ImageUploader, :max_height], 100)
        creator = fake_user!()
        path = static_png_copy!("anim_256.png", 256)

        assert {:ok, _} =
                 Files.upload(ImageUploader, creator, %{path: path, filename: "still_256.png"})

        [stored] = stored_files(creator)
        info = apng_info(stored)
        assert info.frames == 1
        assert info.width == 100 and info.height == 100
      end
    end
  end

  defp upload_apng!(creator, fixture) do
    path = Path.join(@apng_fixtures, fixture)
    assert {:ok, upload} = Files.upload(EmojiUploader, creator, %{path: path, filename: fixture})
    upload
  end

  # the first frame of an APNG as a plain PNG, in a temporary directory (the fixtures are never touched)
  defp static_png_copy!(fixture, _size) do
    dir = Path.join(System.tmp_dir!(), "still_png_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "still.png")
    {:ok, img} = Image.open(Path.join(@apng_fixtures, fixture))
    {:ok, _} = Image.write(img, path)
    refute apng_info(path).frames > 1
    path
  end

  # `{width, height, frames, plays}` from the PNG chunks: `acTL` (present only in an APNG) holds the frame count and the loop count (0 = forever)
  defp apng_info(path) do
    <<137, 80, 78, 71, 13, 10, 26, 10, chunks::binary>> = File.read!(path)
    png_chunks(chunks, %{width: nil, height: nil, frames: 1, plays: nil})
  end

  defp png_chunks(
         <<len::32, type::binary-size(4), data::binary-size(len), _crc::32, rest::binary>>,
         acc
       ) do
    acc =
      case type do
        "IHDR" ->
          <<w::32, h::32, _::binary>> = data
          %{acc | width: w, height: h}

        "acTL" ->
          <<n::32, plays::32>> = data
          %{acc | frames: n, plays: plays}

        _ ->
          acc
      end

    png_chunks(rest, acc)
  end

  defp png_chunks(_, acc), do: acc

  defp use_tools(tools),
    do:
      for({name, val} <- tools, do: Process.put([:bonfire_files, :choose_executable, name], val))

  defp upload!(creator, uploader, fixture) do
    path = Path.join(@fixtures, fixture)
    assert {:ok, upload} = Files.upload(uploader, creator, %{path: path, filename: fixture})
    upload
  end

  defp stored_files(creator) do
    Path.wildcard("data/uploads/#{creator.id}/**/*")
    |> Enum.filter(&File.regular?/1)
  end

  # `{width, height, frames}`, reading every page
  defp image_info(path) do
    {:ok, img} = Image.open(path, pages: :all)

    frames =
      case Vix.Vips.Image.header_value(img, "n-pages") do
        {:ok, n} when is_integer(n) -> n
        _ -> 1
      end

    {Image.width(img), Image.height(img) |> div(frames), frames}
  end

  defp loop(path) do
    {:ok, img} = Image.open(path, pages: :all)
    Vix.Vips.Image.header_value(img, "loop")
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
