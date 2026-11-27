# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.UploadCapabilitiesTest do
  @moduledoc """
  The upload types an instance accepts follow the tools it has: `MediaEdit.capabilities/0` probes them, and `RuntimeConfig.media_config/1` builds every uploader's list (and the composer's `accept`) from the result.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Files.{MediaEdit, RuntimeConfig}

  @heif ~w(image/heic image/heif image/avif)
  @raster ~w(image/jpeg image/png image/webp)

  defp force(name, value), do: Process.put([:bonfire_files, :choose_executable, name], value)

  defp all_tools(value) do
    for name <- [
          "vipsthumbnail",
          "convert",
          Image,
          SvgSanitizer,
          "vipsthumbnail_heif",
          "convert_heif"
        ],
        do: force(name, value)
  end

  defp types(caps), do: RuntimeConfig.media_config(caps).global.all_allowed_media_types

  setup do
    all_tools(true)
    Process.put([:bonfire_files, :env], :prod)
    :ok
  end

  describe "capabilities/0" do
    test "all tools present: everything" do
      assert %{resize: true, heic: true, avif: true, svg: true} = MediaEdit.capabilities()
    end

    test "no resize tool: no resizing" do
      all_tools(false)
      assert %{resize: false, heic: false, avif: false} = MediaEdit.capabilities()
    end

    test "any one resize tool is enough" do
      all_tools(false)
      force("convert", true)
      assert %{resize: true} = MediaEdit.capabilities()
      force("convert", false)
      force(Image, true)
      assert %{resize: true} = MediaEdit.capabilities()
      force(Image, false)
      force("vipsthumbnail", true)
      assert %{resize: true} = MediaEdit.capabilities()
    end

    test "no HEIF decoder: no HEIF, even with resize tools and the Image library" do
      force("vipsthumbnail_heif", false)
      force("convert_heif", false)
      assert %{resize: true, heic: false, avif: false} = MediaEdit.capabilities()
    end

    test "either decoder is enough, with the tool that runs it" do
      force("convert_heif", false)
      assert %{heic: true, avif: true} = MediaEdit.capabilities()

      force("vipsthumbnail_heif", false)
      force("convert_heif", true)
      assert %{heic: true, avif: true} = MediaEdit.capabilities()

      force("convert", false)
      assert %{heic: false, avif: false} = MediaEdit.capabilities()
    end

    test "a decoder of AVIF but not of HEIC (libheif without its HEVC decoder): AVIF only" do
      force("vipsthumbnail_heic", false)
      force("convert_heic", false)
      assert %{heic: false, avif: true} = MediaEdit.capabilities()

      config = RuntimeConfig.media_config(MediaEdit.capabilities())
      assert "image/avif" in config.global.all_allowed_media_types
      refute "image/heic" in config.global.all_allowed_media_types
      refute "image/heif" in config.global.all_allowed_media_types
      assert config.dropped["image/heic"] == :heic
    end

    test "no sanitiser: no SVG, except in dev" do
      force(SvgSanitizer, false)
      assert %{svg: false} = MediaEdit.capabilities()
      Process.put([:bonfire_files, :env], :test)
      assert %{svg: false} = MediaEdit.capabilities()
      Process.put([:bonfire_files, :env], :dev)
      assert %{svg: true} = MediaEdit.capabilities()
    end

    test "the real probes see the tools on this machine" do
      for name <- ["vipsthumbnail", "convert", Image, "vipsthumbnail_heif", "convert_heif"],
          do: Process.delete([:bonfire_files, :choose_executable, name])

      caps = MediaEdit.capabilities()

      assert is_boolean(caps.resize) and is_boolean(caps.heic) and is_boolean(caps.avif) and
               is_boolean(caps.svg)

      # a format is reported as decoded when a tool decodes its sample (not when its loader merely exists: libheif can lack the HEVC decoder)
      priv = Application.app_dir(:bonfire_files, "priv/heif_probe")

      for {format, sample} <- [heic: "sample.heic", avif: "sample.avif"] do
        if System.find_executable("vipsthumbnail") && vips_decodes?(Path.join(priv, sample)),
          do: assert(Map.fetch!(caps, format), "#{format} decodes with vips")
      end
    end

    test "the samples are tiny" do
      for sample <- ["sample.heic", "sample.avif"] do
        assert %{size: size} =
                 File.stat!(Application.app_dir(:bonfire_files, "priv/heif_probe/#{sample}"))

        assert size < 1_000
      end
    end
  end

  describe "RuntimeConfig.media_config/1" do
    test "all present: every type, in every list" do
      caps = %{resize: true, heic: true, avif: true, svg: true}
      config = RuntimeConfig.media_config(caps)

      for type <- @heif ++ @raster ++ ["image/svg+xml", "image/gif", "video/mp4"],
          do: assert(type in config.global.all_allowed_media_types, type)

      for type <- @heif ++ @raster ++ ["image/svg+xml"] do
        assert type in config.uploaders[Bonfire.Files.ImageUploader][:allowed_media_types]
        assert type in config.uploaders[Bonfire.Files.EmojiUploader][:allowed_media_types]
      end

      assert ".heic" in config.global.all_allowed_media_extensions
      assert config.dropped == %{}
    end

    test "no resize tool: no JPEG, PNG, WebP or HEIF anywhere, GIF and video stay" do
      config = RuntimeConfig.media_config(%{resize: false, heic: false, avif: false, svg: true})

      for list <- [
            config.global.all_allowed_media_types
            | Enum.map(config.uploaders, fn {_, o} -> o[:allowed_media_types] end)
          ],
          type <- @raster ++ @heif,
          do: refute(type in list, type)

      assert "image/gif" in config.global.all_allowed_media_types
      assert "video/mp4" in config.global.all_allowed_media_types
      refute ".jpg" in config.global.all_allowed_media_extensions
      assert config.dropped["image/jpeg"] == :resize
    end

    test "no HEIF decoder: no HEIC, HEIF or AVIF, others stay" do
      config = RuntimeConfig.media_config(%{resize: true, heic: false, avif: false, svg: true})

      for type <- @heif do
        refute type in config.global.all_allowed_media_types
        refute type in config.uploaders[Bonfire.Files.ImageUploader][:allowed_media_types]
        refute type in config.uploaders[Bonfire.Files.EmojiUploader][:allowed_media_types]
      end

      for type <- @raster, do: assert(type in config.global.all_allowed_media_types)
      refute ".heic" in config.global.all_allowed_media_extensions
      assert config.dropped["image/avif"] == :avif
      assert config.dropped["image/heic"] == :heic
    end

    test "no sanitiser: no SVG in any uploader" do
      config = RuntimeConfig.media_config(%{resize: true, heic: true, avif: true, svg: false})

      refute "image/svg+xml" in config.global.all_allowed_media_types
      refute "image/svg+xml" in config.global.image_media_types

      for {_uploader, opts} <- config.uploaders,
          do: refute("image/svg+xml" in opts[:allowed_media_types])

      refute ".svg" in config.global.all_allowed_media_extensions
    end

    test "built from the probe" do
      all_tools(false)
      refute "image/jpeg" in types(MediaEdit.capabilities())
      all_tools(true)
      assert "image/avif" in types(MediaEdit.capabilities())
    end
  end

  defp vips_decodes?(sample) do
    case System.cmd("vips", ["avg", sample], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
