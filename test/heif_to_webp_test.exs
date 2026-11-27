# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.HeifToWebpTest do
  @moduledoc """
  HEIC, HEIF and AVIF uploads (images and custom emoji) are converted to WebP: always, resized as the uploader resizes, stripped of their metadata, with the frames of an animated AVIF kept where a tool can read them. The stored file is a `.webp`, served as `image/webp`, and recorded with that type. Where no tool can read the format, the upload is refused, with a message naming the file and the format.

  What each tool reads here:
  - HEIC: vipsthumbnail and ImageMagick. Not the `Image` library: the libvips bundled with it has libheif and AV1 decoders but no HEVC one (it fails to decode the pixels, "Failed to memory copy image"), so a HEIC is refused when it is the only tool.
  - Still AVIF: all three.
  - Animated AVIF: ImageMagick only. libvips reads it only through its ImageMagick loader, blocked as untrusted (`VIPS_BLOCK_UNTRUSTED=TRUE`, set at boot by `MediaEdit.block_untrusted_loaders/0` unless an admin set it), so with vipsthumbnail alone it is refused.

  Fixtures in `test/fixtures/formats/`: `gps.heic` (800x600), `gps.avif` (1200x900), `small_gps.heic` and `small_gps.avif` (100x75) all embed 48.8584 N, 2.2945 E; `anim.avif` is 3 frames of 64x64.
  """
  use Bonfire.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Files
  alias Bonfire.Files.{EmojiUploader, ImageUploader}

  @fixtures Path.expand("fixtures/formats", __DIR__)
  @gps_fixtures Path.expand("fixtures/gps", __DIR__)
  @image_limit 400
  @emoji_size 48

  @tool_branches [
    {"vipsthumbnail only", [{"vipsthumbnail", true}, {"convert", false}, {Image, false}]},
    {"convert only", [{"vipsthumbnail", false}, {"convert", true}, {Image, false}]},
    {"Image library only", [{"vipsthumbnail", false}, {"convert", false}, {Image, true}]}
  ]
  @no_decoders [{"vipsthumbnail", false}, {"convert", false}, {Image, false}]
  @vips_only elem(Enum.at(@tool_branches, 0), 1)
  @convert_only elem(Enum.at(@tool_branches, 1), 1)
  @image_only elem(Enum.at(@tool_branches, 2), 1)

  # the tool branches that can read a fixture: the `Image` library alone can't read a HEIC
  readable? = fn tools, fixture -> not (tools == @image_only and fixture =~ ".heic") end

  if System.find_executable("exiftool") do
    for {branch, tools} <- @tool_branches,
        fixture <- ["gps.heic", "gps.avif"],
        readable?.(tools, fixture) do
      test "an image upload of #{fixture} is stored as a WebP within the limit, with no GPS, with #{branch}" do
        use_tools(unquote(Macro.escape(tools)))
        set_limits()
        creator = fake_user!()

        upload = upload!(creator, ImageUploader, unquote(fixture))

        [stored] = stored_files(creator)
        assert Path.extname(stored) == ".webp"
        assert exif(stored, "MIMEType") == "image/webp"
        assert upload.media_type == "image/webp"
        assert Files.remote_url(nil, upload, :default) |> String.ends_with?(".webp")

        {w, h} = dimensions(stored)
        assert w <= @image_limit and h <= @image_limit, "stored at #{w}x#{h}"
        assert w == @image_limit or h == @image_limit, "shrunk too far: #{w}x#{h}"
        assert gps_leak(stored) == nil
      end
    end

    for {branch, tools} <- @tool_branches,
        fixture <- ["small_gps.heic", "small_gps.avif"],
        uploader <- [ImageUploader, EmojiUploader],
        readable?.(tools, fixture) do
      test "#{inspect(uploader)} converts #{fixture}, already small, to a WebP with no GPS, with #{branch}" do
        use_tools(unquote(Macro.escape(tools)))
        set_limits()
        creator = fake_user!()

        upload = upload!(creator, unquote(uploader), unquote(fixture))

        [stored] = stored_files(creator)
        assert Path.extname(stored) == ".webp"
        assert exif(stored, "MIMEType") == "image/webp"
        assert upload.media_type == "image/webp"
        assert gps_leak(stored) == nil
      end
    end

    for {branch, tools} <- @tool_branches, readable?.(tools, "gps.heic") do
      test "an emoji of gps.heic is shrunk to the emoji size as a WebP with no GPS, with #{branch}" do
        use_tools(unquote(Macro.escape(tools)))
        set_limits()
        creator = fake_user!()

        upload = upload!(creator, EmojiUploader, "gps.heic")

        [stored] = stored_files(creator)
        assert Path.extname(stored) == ".webp"
        assert upload.media_type == "image/webp"
        {w, h} = dimensions(stored)
        assert w <= @emoji_size and h <= @emoji_size, "emoji stored at #{w}x#{h}"
        assert w == @emoji_size or h == @emoji_size, "emoji shrunk too far: #{w}x#{h}"
        assert gps_leak(stored) == nil
      end
    end

    # ImageMagick keeps the frames of an animated AVIF (exiftool doesn't count the frames of a WebP, `vipsheader` does)
    test "an animated AVIF emoji keeps its 3 frames as an animated WebP, with convert only" do
      use_tools(@convert_only)
      set_limits()
      creator = fake_user!()

      upload = upload!(creator, EmojiUploader, "anim.avif")

      [stored] = stored_files(creator)
      assert Path.extname(stored) == ".webp"
      assert upload.media_type == "image/webp"
      assert exif(stored, "WebP_Flags") == "Animation"
      assert frame_count(stored) == 3
    end

    test "controls: a JPEG and a PNG upload still keep their own type" do
      set_limits()
      creator = fake_user!()

      jpeg = upload!(creator, ImageUploader, "gps.jpg", @gps_fixtures)
      png = upload!(creator, ImageUploader, "gps.png", @gps_fixtures)

      assert jpeg.media_type == "image/jpeg"
      assert png.media_type == "image/png"
      exts = creator |> stored_files() |> Enum.map(&Path.extname/1) |> Enum.sort()
      assert exts == [".jpg", ".png"]
    end

    test "controls: a WebP emoji still goes the WebP way" do
      set_limits()
      creator = fake_user!()
      upload = upload!(creator, EmojiUploader, "gps_anim.webp", @gps_fixtures)
      assert upload.media_type == "image/webp"
      assert [stored] = stored_files(creator)
      assert Path.extname(stored) == ".webp"
      assert gps_leak(stored) == nil
    end
  end

  # whether vipsthumbnail, run as the upload runs it, opens the animated AVIF here: libvips reads one only through its ImageMagick loader, which is blocked as untrusted (boot sets `VIPS_BLOCK_UNTRUSTED` unless an admin set it, so this sets it the same way first), and open where an admin set it to something else
  vips_reads_anim? =
    if System.find_executable("vipsthumbnail") do
      Bonfire.Files.MediaEdit.block_untrusted_loaders()
      out = Path.join(System.tmp_dir!(), "anim_probe_#{System.unique_integer([:positive])}.webp")

      {_, status} =
        System.cmd(
          "vipsthumbnail",
          [Path.join(@fixtures, "anim.avif") <> "[n=-1]", "--size", "400x400>", "-o", out],
          stderr_to_stdout: true
        )

      File.rm(out)
      status == 0
    else
      false
    end

  @vips_reads_anim vips_reads_anim?

  # (tools, what they can't read, fixtures to try)
  @refusals [
    {"no tool", "no tool can read it", @no_decoders, ["gps.heic", "gps.avif"]},
    {"the Image library only", "it has no HEVC decoder", @image_only,
     ["gps.heic", "small_gps.heic"]}
    | if(@vips_reads_anim,
        do: [],
        else: [
          {"vipsthumbnail only", "libvips blocks the loader of an animated AVIF", @vips_only,
           ["anim.avif"]}
        ]
      )
  ]

  if @vips_reads_anim do
    for uploader <- [ImageUploader, EmojiUploader] do
      test "#{inspect(uploader)} converts anim.avif to a WebP with vipsthumbnail only, as its loader isn't blocked here" do
        use_tools(unquote(Macro.escape(@vips_only)))
        set_limits()
        creator = fake_user!()

        upload = upload!(creator, unquote(uploader), "anim.avif")

        [stored] = stored_files(creator)
        assert Path.extname(stored) == ".webp"
        assert upload.media_type == "image/webp"
      end
    end
  end

  for {branch, why, tools, fixtures} <- @refusals,
      uploader <- [ImageUploader, EmojiUploader],
      fixture <- fixtures do
    test "#{inspect(uploader)} refuses #{fixture}, naming the file and format, with #{branch}: #{why}" do
      use_tools(unquote(Macro.escape(tools)))
      set_limits()
      creator = fake_user!()
      path = Path.join(@fixtures, unquote(fixture))
      ext = Path.extname(unquote(fixture)) |> String.trim_leading(".")

      assert {:error, %Bonfire.Fail{} = fail} =
               Files.upload(unquote(uploader), creator, %{path: path}, %{
                 client_name: "holiday.#{ext}"
               })

      assert fail.code == :image_conversion_failed
      assert fail.message =~ "holiday"
      assert fail.message =~ String.upcase(ext)
      assert stored_files(creator) == []
    end
  end

  defp use_tools(tools),
    do:
      for({name, val} <- tools, do: Process.put([:bonfire_files, :choose_executable, name], val))

  defp set_limits do
    Process.put([:bonfire_files, ImageUploader, :max_width], @image_limit)
    Process.put([:bonfire_files, ImageUploader, :max_height], @image_limit)
    Process.put([:bonfire_files, EmojiUploader, :max_size], @emoji_size)
  end

  defp upload!(creator, uploader, fixture, dir \\ @fixtures) do
    path = Path.join(dir, fixture)
    assert {:ok, upload} = Files.upload(uploader, creator, %{path: path, filename: fixture})
    upload
  end

  defp stored_files(creator) do
    Path.wildcard("data/uploads/#{creator.id}/**/*")
    |> Enum.filter(&File.regular?/1)
  end

  defp exif(path, tag) do
    {out, 0} = System.cmd("exiftool", ["-s3", "-#{tag}", path])
    String.trim(out)
  end

  defp dimensions(path) do
    {String.to_integer(exif(path, "ImageWidth")), String.to_integer(exif(path, "ImageHeight"))}
  end

  defp frame_count(path) do
    {out, 0} = System.cmd("vipsheader", ["-f", "n-pages", path])
    out |> String.trim() |> String.to_integer()
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
