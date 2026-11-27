defmodule Bonfire.Files.MediaEdit do
  import Untangle
  # use Arrows
  use Bonfire.Common.Localise
  use Bonfire.Common.Config
  use Bonfire.Common.Settings
  alias Bonfire.Files
  alias Bonfire.Common.Extend
  alias Bonfire.Common.Types

  @yes? ~w(true yes 1)
  @vips_save_exts ~w(jpg jpeg jpe jfif png gif webp)
  @animation_fields ~w(page-height n-pages delay loop gif-delay gif-loop background)

  # the tools that shrink an image, in the order the transforms try them (the `Image` library comes last)
  @resize_executables ["vipsthumbnail", "convert"]

  # the tools that convert HEIC, HEIF and AVIF to WebP in `heif_to_webp/4`, in order: `{command, executable, {probe executable, probe args, coders its output must list}}`. A tool is only worth accepting these for if its probe passes (libheif is a separate package on some systems). The `Image` library is tried last by `heif_to_webp/4` but doesn't count for `capabilities/0`, as it can lack an HEVC decoder.
  @heif_tools [
    {:vipsthumbnail, "vipsthumbnail", {"vips", ["heifload"], nil}},
    {:convert, "convert", {"convert", ["-list", "format"], ["HEIC", "AVIF"]}}
  ]

  @doc "Use a small indirection so tests can override tool availability by setting `Process.put([:bonfire_files, :choose_executable, name], value)` where `value` can be `false` (force missing), `true` (force present), or a binary/atom to manually override the path/module.
  Falls back to `System.find_executable/1` or `Extend.module_available?/1`."
  def choose_executable(_key, name) when is_binary(name) do
    case choose_executable_config(name) do
      nil -> System.find_executable(name)
      true -> System.find_executable(name) || name
      false -> nil
      s when is_binary(s) -> System.find_executable(s) || s
    end
    |> debug("choose_executable_#{name}")
  end

  def choose_executable(_key, name) when is_atom(name) do
    case choose_executable_config(name) do
      nil -> Extend.module_available?(name) && name
      true -> name
      false -> nil
      s when is_atom(s) -> s
    end
    |> debug("choose_executable_#{name}")
  end

  @doc """
  What this machine can do with an upload, probed from the tools found (so call it once, at boot, not per upload):

  - `:resize`: a tool that can shrink a JPEG, PNG or WebP (`vipsthumbnail`, ImageMagick's `convert`, or the `Image` library)
  - `:heif`: a decoder for HEIC, HEIF and AVIF (libvips with its `heifload`, or ImageMagick with its HEIC or AVIF coder). The `Image` library alone doesn't count, as it can lack an HEVC decoder.
  - `:svg`: `SvgSanitizer` is loaded, or this is a dev build (which stores SVG unsanitised)

  Each probe can be forced on or off like any tool, with `Process.put([:bonfire_files, :choose_executable, name], true | false)` for `"vipsthumbnail"`, `"convert"`, `Image` and `SvgSanitizer`. The HEIF decoder probe of a tool is forced with the name `"<tool>_heif"` (`"vipsthumbnail_heif"`, `"convert_heif"`). The environment is set with`Process.put([:bonfire_files, :env], :dev)`.
  """
  def capabilities do
    %{
      resize: !!resize_tool(),
      heif: Enum.any?(@heif_tools, &heif_decoder?/1),
      svg: !!svg_sanitizer() || current_env() == :dev
    }
  end

  @doc "The first tool that can shrink a JPEG, PNG or WebP (`@resize_executables` in order, then the `Image` library), or `nil`. The transforms (`image/4`, `thumbnail/3`, `banner/4`) try the same tools in the same order."
  def resize_tool(key \\ :image) do
    Enum.find_value(@resize_executables, &choose_executable(key, &1)) ||
      choose_executable(key, Image)
  end

  @doc "The module that makes an SVG safe, or `nil` when it isn't compiled in."
  def svg_sanitizer, do: choose_executable(:svg_sanitizer, SvgSanitizer)

  defp current_env, do: ProcessTree.get([:bonfire_files, :env]) || Config.env()

  # a conversion tool decodes if it is there and its probe says it has a HEIF coder
  defp heif_decoder?({_cmd, executable, {probe_executable, probe_args, coders}}) do
    !!(choose_executable(:image, executable) &&
         probe(executable, probe_executable, probe_args, coders))
  end

  # asks a tool what it can do (a failure, or no answer within 5 seconds, is "no"), unless a test forces the answer by the name of the tool
  defp probe(name, executable, args, coders) do
    case choose_executable_config("#{name}_heif") do
      nil -> run_probe(choose_executable(:image, executable), args, coders)
      forced -> forced == true
    end
  end

  defp run_probe(exe, args, coders) when is_binary(exe) do
    {out, 0} =
      Task.async(fn -> System.cmd(exe, args, stderr_to_stdout: true) end) |> Task.await(5_000)

    is_nil(coders) or
      Regex.match?(Regex.compile!("^\\s*(#{Enum.join(coders, "|")})\\s", "m"), out)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp run_probe(_exe, _args, _coders), do: false

  defp choose_executable_config(name) do
    # Config.get([:bonfire_files, :choose_executable, name])
    ProcessTree.get([:bonfire_files, :choose_executable, name])
    |> debug("config_executable_#{name}")
  end

  @doc "The transformation that shrinks an uploaded image to fit the given size and removes its metadata, or `nil` if its type can't be handled. A GIF or WebP keeps all its frames."
  def image(filename, max_width, max_height, scope \\ nil) do
    # the type of the image is the one found in its bytes (as in the `scope`, when given), not the one the uploader's file name claims
    ext = image_ext(filename, scope)
    # the name the file is stored under, which the output of the tool must have the extension of
    stored_ext = Files.file_extension_only(filename)

    max_size = "#{max_width}x#{max_height}"
    quality = image_quality()

    cond do
      svg?(filename, scope) ->
        sanitize_svg()

      heif_format(filename, scope) ->
        heif_to_webp(filename, max_width, max_height, scope)

      ext not in ["jpg", "jpeg", "png", "gif", "webp"] ->
        # to avoid error `svgload: operation is blocked`
        nil

      # vips picks the format to save from the extension, so a name without a known one can't go through it
      stored_ext in @vips_save_exts and choose_executable(:image, "vipsthumbnail") ->
        {:vipsthumbnail,
         fn input, output ->
           # a list, which `Waffle.Transformations.Convert` passes on as it is: a string would be split on spaces, cutting a path that has one
           # `>`: only shrink, so a smaller image keeps its size (as `convert`'s `>` and `Image`'s `resize: :down` below)
           [vips_input(input, ext), "--size", "#{max_size}>", "--linear", "--export-profile"] ++
             ["srgb", "-o", "#{output}#{vips_save_opts(ext, quality)}"]
         end, stored_ext}

      choose_executable(:image, "convert") ->
        {:convert,
         "-strip #{convert_animation_opts(ext)}-thumbnail #{max_size}> -quality #{quality} -limit area 10MB -limit disk 50MB"}

      true ->
        fn _version, %{path: filename} = waffle_file ->
          image_resize_thumbnail(filename, max_size, waffle_file,
            crop: :none,
            resize: :down,
            animated: animated?(ext)
          )
        end
    end
  end

  def thumbnail(filename, max_size, scope \\ nil) do
    ext = image_ext(filename, scope)
    stored_ext = Files.file_extension_only(filename)
    quality = image_quality()

    cond do
      svg?(filename, scope) ->
        sanitize_svg()

      ext not in ["jpg", "jpeg", "png", "gif", "webp"] ->
        # avoid error `svgload: operation is blocked`
        nil

      stored_ext in @vips_save_exts and choose_executable(:thumbnail, "vipsthumbnail") ->
        {:vipsthumbnail,
         fn input, output ->
           # a list, so a path with a space in it stays one argument (see `image/3`). `>`: only shrink, so a smaller image keeps its size (cropped to the square where it's bigger)
           [input, "--smartcrop", "attention", "-s", "#{max_size}x#{max_size}>", "--linear"] ++
             ["--export-profile", "srgb", "-o", "#{output}#{vips_save_opts(ext, quality)}"]
         end, stored_ext}

      choose_executable(:thumbnail, "convert") ->
        # `^>`: fill the square, only shrinking; `-crop` (not `-extent`) never enlarges the canvas of a smaller image
        {:convert,
         "-strip -thumbnail #{max_size}x#{max_size}^> -gravity center -crop #{max_size}x#{max_size}+0+0 +repage -quality #{quality} -limit area 10MB -limit disk 20MB"}

      true ->
        fn _version, %{path: filename} = waffle_file ->
          image_resize_thumbnail(filename, max_size, waffle_file, crop: :attention, resize: :down)
        end
    end
  end

  def thumbnail_video(filename, max_size, scrub_opts) do
    ext = Files.file_extension_only(filename)

    # TODO: convert in background rather than block publication (but federation would need to be triggered when file is ready)

    cond do
      choose_executable(:video, "ffmpeg") ->
        {max_width, max_height} = width_and_height(max_size)

        {:ffmpeg,
         fn input, output ->
           # a list, so a path with a space in it stays one argument (see `image/3`)
           ["-hide_banner", "-i", input, "-frames:v", "1"] ++
             [
               "-vf",
               "thumbnail=150,scale=w='min(iw,#{max_width})':h='min(ih,#{max_height})':force_original_aspect_ratio=decrease",
               output
             ]
         end, "jpg"}

      # -frames:v 1: number of frames
      # -vf thumbnail=150: analyse N frames and pick most "significant" one
      # -vf scale=w='min(iw,W)':h='min(ih,H)':force_original_aspect_ratio=decrease: fit within WxH keeping the aspect ratio, only shrinking

      # ffmpegthumbnailer can't only shrink, so the frame comes at the video's own size (`-s 0`), then is resized as an image, only shrinking
      ffmpegthumbnailer = choose_executable(:video, "ffmpegthumbnailer") ->
        {fn _version, %{path: input} = waffle_file ->
           ffmpegthumbnailer_frame(ffmpegthumbnailer, input, max_size, scrub_opts, waffle_file)
         end, fn _version, _file -> "jpg" end}

      # -t: time to seek to (percentage or absolute time hh:mm:ss) (default: 10)
      # -s: size of the generated thumbnail in pixels (use 0 for original size) (default value: 128)
      # -q: image quality (0 = bad, 10 = best) (default: 8) only applies to jpeg output
      # -a: ignore aspect ratio and generate square thumbnail
      # -c: override image format (jpeg or png) (default: determined by filename)
      # -w: workaround some issues in older versions of ffmpeg (only use if you experience problems like 100% cpu usage on certain files)
      # -rN: repeat thumbnail generation each N seconds, N=0 means disable repetition (default: 0)
      # -f: use this option to overlay a movie strip on the generated thumbnail

      ext not in ["mp4", "mpg", "mpeg"] ->
        # TODO: support other sources, or extract thumbnail from converted video instead
        nil

      choose_executable(:video, Image.Video) ->
        {fn _version, %{path: filename} = waffle_file ->
           video_image_thumbnail(filename, max_size, scrub_opts, waffle_file)
           |> debug("thumbnail_video_ran")
         end, fn _version, _file -> "jpg" end}

      # choose_executable(:video, "convert") ->
      #   {:convert,
      #    "[#{scrub*30}] -strip -thumbnail #{max_size}x#{max_size}^ -gravity center -crop #{max_size}x#{max_size}+0+0 -limit area 10MB -limit disk 20MB"}

      true ->
        nil
    end
    |> debug("thumbnail_video")
  end

  # where the image can't be resized, the frame is kept at the video's own size: never scaled up, though not shrunk either
  defp ffmpegthumbnailer_frame(ffmpegthumbnailer, input, max_size, scrub_opts, waffle_file) do
    frame = "#{Waffle.File.generate_temporary_path()}.jpg"

    # a list, so a path with a space in it stays one argument (see `image/3`)
    args = ["-i", input, "-t", "#{scrub_opts[:percent]}", "-s", "0", "-q", "9", "-o", frame]

    with {_, 0} <- System.cmd(to_string(ffmpegthumbnailer), args, stderr_to_stdout: true) do
      case image_resize_thumbnail(frame, max_size, waffle_file,
             tmp_path: "#{Waffle.File.generate_temporary_path()}.jpg",
             crop: :none,
             resize: :down
           ) do
        {:ok, %Waffle.File{path: path}} = resized when path != input ->
          File.rm(frame)
          resized

        _ ->
          {:ok, %Waffle.File{waffle_file | path: frame, is_tempfile?: true}}
      end
    else
      e ->
        error(e, "Could not generate a video thumbnail")
        nil
    end
  end

  # a size given as `"WxH"` (as `VideoUploader` does) or as one number for both
  defp width_and_height(size) do
    case String.split(to_string(size), "x") do
      [width, height] -> {width, height}
      [both] -> {both, both}
    end
  end

  @video_media_exts %{"video/mp4" => "mp4", "video/webm" => "webm"}

  @doc "The transformation that removes the metadata (the location included) from an MP4 or WebM without encoding it again: video and audio are copied as they are, while the global and stream metadata, the chapters and any other track (eg. a GPS data track) are dropped. The type is the one found in the file's bytes (as `scope.file_info.media_type`). `nil` for other types, or where `ffmpeg` is not available."
  def video_strip(scope) do
    with %{file_info: %{media_type: media_type}} <- scope,
         ext when is_binary(ext) <- @video_media_exts[media_type],
         ffmpeg when not is_nil(ffmpeg) <- choose_executable(:video, "ffmpeg") do
      {ffmpeg,
       fn input, output ->
         # `0:a?` so a video with no audio still goes through; `+faststart` (MP4 only) keeps it playable while it downloads
         ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", input] ++
           ["-map", "0:v", "-map", "0:a?", "-map_metadata", "-1", "-map_chapters", "-1"] ++
           ["-c", "copy"] ++
           if(ext == "mp4", do: ["-movflags", "+faststart"], else: []) ++
           [output]
       end, ext}
    else
      _ -> nil
    end
  end

  @doc "Converts video into a browser-supported format. NOTE: in dev mode on OSX, you can install ffmpeg with maximal features using https://gist.github.com/Piasy/b5dfd5c048eb69d1b91719988c0325d8?permalink_comment_id=3812563#gistcomment-3812563"
  def video_convert(_filename) do
    # {
    #  to VP9 webm, see https://trac.ffmpeg.org/wiki/Encode/VP9
    # :ffmpeg,
    #      fn original_path, new_path ->
    #        " -i #{original_path} -c:v libvpx-vp9 -b:v 0 -crf 30 -pass 1 -an -f null /dev/null && \
    # ffmpeg -i #{original_path} -c:v libvpx-vp9 -b:v 0 -crf 30 -pass 2 -c:a libopus #{new_path}"
    #      end, :webm}

    {
      # to AV1 mp4
      :ffmpeg,
      fn original_path, new_path ->
        # -map_metadata -1 will remove video metadata (like the name of a tool that was used initially to create a video). Sometimes metadata is useful, but can be bad for privacy.
        # -c:a libopus or -c:a libfdk_aac selects an audio codec.
        # -c:v selects a video codec, a library to compress images into a video stream.
        # -qp sets your size/quality balance for rav1e codec for AV1. The scale is from 0 to 255.
        # -tile-columns 2 -tile-rows 2 is for speed enhancements, at the cost of a small loss in compression efficiency.
        # -pix_fmt yuv420p (pixel format) is a trick to reduce the size of a video. Basically, it uses full resolution for brightness and a smaller resolution for color. It is a way to fool a human eye, and you can safely remove this argument if it does not work in your case.
        # -movflags +faststart moves the important information to the beginning of the file. It allows browser to start playing video during downloading.
        # -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" is a way to ensure the produced video will always have an even size (some codecs will only work with sizes like 300x200 and 302x200, but not with 301x200). This option tells FFmpeg to scale the source to the closest even resolution. If your video dimensions were even in the first place, it would not do anything.
        " -i #{original_path}
        -map_metadata -1
        -c:a libopus
        -c:v librav1e
        -qp 80
        -tile-columns 2
        -tile-rows 2
        -pix_fmt yuv420p
        -movflags +faststart
        -vf scale=trunc(iw/2)*2:trunc(ih/2)*2
        #{new_path}"
      end,
      :mp4
    }
    |> debug()
  end

  def thumbnail_pdf(_filename, scope) do
    max_size =
      Settings.get([Bonfire.Files, :max_sizes, :pdf], 1024,
        context: scope,
        name: l("PDF preview max size"),
        description: l("Set a maximum width/height for preview images generated for PDFs")
      )

    cond do
      choose_executable(:thumbnail_pdf, "pdftocairo") ->
        {:pdftocairo,
         fn original_path, new_path ->
           " -png -singlefile -scale-to #{max_size} #{original_path} #{String.slice(new_path, 0..-5//1)}"
         end, :png}

      choose_executable(:thumbnail_pdf, "vips") ->
        {:vips,
         fn original_path, new_path ->
           " copy #{original_path}[n=1,page=1,dpi=144] #{String.slice(new_path, 0..-5)}"
         end, :png}

      true ->
        nil
    end
  catch
    :exit, e ->
      error(e)
      nil

    e ->
      error(e)
      nil
  end

  def banner(filename, max_width, max_height, scope \\ nil) do
    ext = image_ext(filename, scope)
    stored_ext = Files.file_extension_only(filename)

    max_size = "#{max_width}x#{max_height}"
    quality = image_quality()

    cond do
      svg?(filename, scope) ->
        sanitize_svg()

      ext not in ["jpg", "jpeg", "png", "gif", "webp"] ->
        # avoid error `svgload: operation is blocked`
        nil

      stored_ext in @vips_save_exts and choose_executable(:thumbnail, "vipsthumbnail") ->
        {:vipsthumbnail,
         fn input, output ->
           # `--smartcrop` fills the box, so a bigger image is cropped to an exact 3:1; `>`: only shrink, so a smaller one keeps its size. A list, so a path with a space in it stays one argument (see `image/3`)
           [input, "--smartcrop", "attention", "--size", "#{max_size}>", "--linear"] ++
             ["--export-profile", "srgb", "-o", "#{output}#{vips_save_opts(ext, quality)}"]
         end, stored_ext}

      choose_executable(:thumbnail, "convert") ->
        # `^>` scales to fill, only shrinking, then `-crop` center-crops a bigger image to an exact 3:1 (matches the vips path); unlike `-extent`, it never pads a smaller one out to the box
        # `-background none` keeps PNG transparency rather than flattening it onto white
        {:convert,
         "-strip -background none -resize #{max_size}^> -gravity center -crop #{max_size}+0+0 +repage -quality #{quality} -limit area 10MB -limit disk 50MB"}

      true ->
        fn _version, %{path: filename} = waffle_file ->
          image_resize_thumbnail(filename, max_size, waffle_file, crop: :attention, resize: :down)
        end
    end
  end

  @doc "Whether the file is an SVG: by the type found in its bytes (as in the `scope`, when given), else by the extension of its name."
  def svg?(filename, scope \\ nil) do
    case scope do
      %{file_info: %{media_type: "image/svg+xml"}} -> true
      _ -> Files.file_extension_only(filename) == "svg"
    end
  end

  @doc """
  The transformation that makes an SVG safe to serve: scripts, event handlers, `foreignObject`, external references and the like are removed (and with them the `<metadata>`), with `SvgSanitizer` (an optional dependency, only in builds that have its precompiled binaries).

  Where that is not available the SVG is stored as it is in dev only, and refused elsewhere. An SVG that can't be sanitised is refused too.
  """
  def sanitize_svg do
    fn _version, %Waffle.File{path: path} = waffle_file ->
      with {:ok, svg} <- File.read(path),
           {:ok, clean} <- sanitize_svg_binary(svg) do
        if clean == svg do
          {:ok, waffle_file}
        else
          tmp_path = Waffle.File.generate_temporary_path(waffle_file)

          with :ok <- File.write(tmp_path, clean) do
            {:ok, %Waffle.File{waffle_file | path: tmp_path, is_tempfile?: true}}
          end
        end
      end
    end
  end

  @doc "Sanitises the bytes of an SVG, see `sanitize_svg/0`. Returns `{:ok, binary}` or `{:error, %Bonfire.Fail{}}`."
  def sanitize_svg_binary(svg) when is_binary(svg) do
    cond do
      sanitizer = svg_sanitizer() ->
        case sanitizer.sanitize(svg) do
          {:ok, clean} ->
            {:ok, clean}

          {:error, reason} ->
            error(reason, "Could not sanitise SVG")

            {:error,
             %Bonfire.Fail{
               code: :svg_unsanitisable,
               message:
                 l(
                   "This SVG file could not be made safe (it may be malformed or too big). Please upload a different file, or a PNG or JPEG version of it."
                 ),
               status: 422
             }}
        end

      # unsanitised SVG is only for developing on a machine that can't have the sanitiser
      current_env() == :dev ->
        {:ok, svg}

      true ->
        {:error,
         %Bonfire.Fail{
           code: :svg_sanitiser_unavailable,
           message:
             l(
               "This instance can't make SVG files safe, so it doesn't accept them. Please upload a PNG or JPEG instead, or ask the instance admins."
             ),
           status: 422
         }}
    end
  end

  @doc "JPEG/WebP quality (1-100) used when resizing uploaded images. Defaults to 90 to avoid the visible degradation of ImageMagick's implicit quality 75."
  def image_quality do
    Config.get([:bonfire_files, :image_quality], 90,
      name: l("Image quality"),
      description: l("Quality (1-100) used when re-encoding resized JPEG/WebP uploads")
    )
  end

  @doc "The transformation that removes the metadata (GPS included) from a GIF or WebP without decoding and encoding it again, so its frames come out as they went in. `nil` for other types, or where `gifsicle` (GIF) or `webpmux` (WebP) is not available."
  def strip_metadata(filename, scope \\ nil), do: strip_metadata_tool(image_ext(filename, scope))

  # the raster types the tools here can transform
  @raster_media_types ~w(image/jpeg image/png image/gif image/webp)

  @doc "The extension of the image type found in the file's bytes (as `scope.file_info.media_type`, which the uploaders get), or that of the file name where there is none or it isn't one of the types handled here."
  def image_ext(filename, scope \\ nil) do
    with %{file_info: %{media_type: media_type}} when media_type in @raster_media_types <- scope,
         ext when is_binary(ext) <- Bonfire.Files.MimeTypes.canonical_extension(media_type) do
      ext
    else
      _ -> Files.file_extension_only(filename)
    end
  end

  # `--no-extensions` drops the XMP and other application extensions: gifsicle reads the loop count out of its extension and writes it back itself, so looping stays
  defp strip_metadata_tool("gif") do
    if gifsicle = choose_executable(:strip, "gifsicle") do
      # no output extension given: the file keeps the one of its name
      {gifsicle,
       fn input, output ->
         ["--no-comments", "--no-names", "--no-extensions", input, "-o", output]
       end}
    end
  end

  # one `-strip` per run: the EXIF chunk goes, then the XMP one. The colour profile stays, it has no location
  defp strip_metadata_tool("webp") do
    if webpmux = choose_executable(:strip, "webpmux") do
      fn _version, %{path: input} = waffle_file ->
        # the file keeps the extension of its name
        without_exif = Waffle.File.generate_temporary_path(waffle_file)
        output = Waffle.File.generate_temporary_path(waffle_file)

        with {_, 0} <-
               System.cmd(to_string(webpmux), ["-strip", "exif", "-o", without_exif, input],
                 stderr_to_stdout: true
               ),
             {_, 0} <-
               System.cmd(to_string(webpmux), ["-strip", "xmp", "-o", output, without_exif],
                 stderr_to_stdout: true
               ) do
          File.rm(without_exif)
          {:ok, %Waffle.File{waffle_file | path: output, is_tempfile?: true}}
        else
          e ->
            File.rm(without_exif)
            error(e, "Could not strip the metadata of the WebP")
            {:error, "Could not strip the metadata of the WebP"}
        end
      end
    end
  end

  defp strip_metadata_tool(_ext), do: nil

  defp animated?(ext), do: ext in ["gif", "webp"]

  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  @doc """
  `{width, height}` of the image at `path` if it is an APNG (animated PNG), else `nil`. An APNG is a PNG with an `acTL` chunk before its first `IDAT` chunk: it is found from those bytes alone, since it has the type and extension of a PNG, and its size is read from the `IHDR` chunk, so neither needs a tool or the `Image` library.

  No tool here writes an APNG, so resizing one keeps only its first frame: see `apng_transform/3`.
  """
  def apng_size(path) when is_binary(path) do
    case File.open(path, [:read, :binary], &apng_signature/1) do
      {:ok, size} -> size
      _ -> nil
    end
  end

  def apng_size(_), do: nil

  defp apng_signature(io) do
    case IO.binread(io, 8) do
      @png_signature -> apng_scan(io, nil)
      _ -> nil
    end
  end

  # chunks are walked up to the first `IDAT`, skipping the data and the CRC of each
  defp apng_scan(io, size) do
    case IO.binread(io, 8) do
      <<13::32, "IHDR">> ->
        with <<width::32, height::32, _::binary>> <- IO.binread(io, 13),
             {:ok, _} <- :file.position(io, {:cur, 4}) do
          apng_scan(io, {width, height})
        else
          _ -> nil
        end

      <<_::32, "acTL">> ->
        size

      <<_::32, "IDAT">> ->
        nil

      <<length::32, _type::binary-size(4)>> ->
        case :file.position(io, {:cur, length + 4}) do
          {:ok, _} -> apng_scan(io, size)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  What to do with the file at `path` when it may be an APNG: `nil` if it isn't one (the caller goes on to its usual transformation), `:noaction` if it is one that fits in `max_width` x `max_height` (stored as it is, so its frames and loop stay; the location check still applies), else a transformation that refuses it with a `%Bonfire.Fail{}`, since resizing it would flatten it to its first frame.
  """
  def apng_transform(path, max_width, max_height) do
    case apng_size(path) do
      nil ->
        nil

      {width, height} when width <= max_width and height <= max_height ->
        :noaction

      _ ->
        fn _version, _waffle_file ->
          {:error,
           %Bonfire.Fail{
             code: :apng_too_big,
             message:
               l(
                 "This animated PNG is bigger than %{width}x%{height} pixels, and can't be made smaller without losing its animation. Please upload a smaller animated image (at most %{width}x%{height} pixels), or a still one.",
                 width: max_width,
                 height: max_height
               ),
             status: 422
           }}
        end
    end
  end

  @heif_formats %{"image/heic" => "HEIC", "image/heif" => "HEIF", "image/avif" => "AVIF"}
  @heif_extensions %{"heic" => "HEIC", "heif" => "HEIF", "avif" => "AVIF"}

  # the name of the HEIC, HEIF or AVIF format of the image (by the type found in its bytes where known, else by the file name), or `nil` for any other
  defp heif_format(filename, scope) do
    case scope do
      %{file_info: %{media_type: media_type}} when is_binary(media_type) ->
        Map.get(@heif_formats, media_type)

      _ ->
        Map.get(@heif_extensions, Files.file_extension_only(filename))
    end
  end

  @doc """
  The transformation that converts a HEIC, HEIF or AVIF image to WebP, always (even when it is small enough), shrunk to fit the given size and with its metadata removed. The file is then stored as a `.webp`. The frames of an animated AVIF are kept by ImageMagick: libvips reads an animated AVIF only through its ImageMagick loader, which is blocked as untrusted (`VIPS_BLOCK_UNTRUSTED`, set when the `:image` application starts), so `vipsthumbnail` can't open one.

  It tries `vipsthumbnail`, then ImageMagick, then the `Image` library, whichever is available and able to read the format (the libheif support of each is a separate package on some systems). When none can, the result is an error naming the file and its format, so the original is never stored as it was.
  """
  def heif_to_webp(filename, max_width, max_height, scope \\ nil) do
    max_size = "#{max_width}x#{max_height}"
    quality = image_quality()
    format = heif_format(filename, scope) || "HEIC"
    name = (is_map(scope) && Map.get(scope, :client_name)) || Path.basename(filename)

    # `>`: only shrink, so a smaller image keeps its size
    heif_args = fn
      :vipsthumbnail ->
        fn input, output ->
          ["#{input}[n=-1]", "--size", "#{max_size}>", "--linear", "--export-profile", "srgb"] ++
            ["-o", "#{output}#{vips_save_opts("webp", quality)}"]
        end

      :convert ->
        fn input, output ->
          [input, "-auto-orient", "-coalesce", "-strip", "-thumbnail", "#{max_size}>"] ++
            ["-quality", "#{quality}", "-limit", "area", "10MB", "-limit", "disk", "50MB", output]
        end
    end

    fn _version, %{path: input} = waffle_file ->
      converted =
        Enum.find_value(@heif_tools, fn {cmd, executable, _probe} ->
          with true <- !!choose_executable(:image, executable),
               {:ok, file} <-
                 Waffle.Transformations.Convert.apply(cmd, waffle_file, heif_args.(cmd), "webp") do
            file
          else
            err ->
              debug(err, "could not convert #{format} with #{executable}")
              nil
          end
        end) || heif_to_webp_with_image_library(input, max_size, waffle_file)

      case converted do
        %Waffle.File{} = file ->
          {:ok, %{file | file_name: Path.rootname(waffle_file.file_name) <> ".webp"}}

        _ ->
          {:error,
           %Bonfire.Fail{
             code: :image_conversion_failed,
             message:
               l(
                 "%{file} is a %{format} image, which this instance could not convert. Please upload a JPEG or PNG instead, or ask the instance admins to install Vips or ImageMagick with %{format} support.",
                 file: name,
                 format: format
               ),
             status: 422
           }}
      end
    end
  end

  defp heif_to_webp_with_image_library(input, max_size, waffle_file) do
    if choose_executable(:image, Image) do
      # in a process of its own: where the library has no decoder for the format, it can exit instead of returning an error
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          # so the tool settings of the caller apply here too
          Process.put(:"$callers", [parent | List.wrap(Process.get(:"$callers"))])

          result =
            image_resize_thumbnail(input, max_size, waffle_file,
              crop: :none,
              resize: :down,
              animated: true,
              tmp_path: Waffle.File.generate_temporary_path("webp")
            )

          exit({:converted, result})
        end)

      receive do
        {:DOWN, ^ref, :process, ^pid, {:converted, {:ok, %Waffle.File{} = file}}} ->
          file

        {:DOWN, ^ref, :process, ^pid, reason} ->
          debug(reason, "Image library could not convert") && nil
      after
        15_000 ->
          Process.exit(pid, :kill)
          nil
      end
    end
  end

  # all the frames of a GIF/WebP, not only the first (a static image has one, so it is the same)
  defp vips_input(input, ext), do: if(animated?(ext), do: "#{input}[n=-1]", else: input)

  # ImageMagick resizes each frame only once they are all full frames, else the later ones (stored as differences) come out wrong
  defp convert_animation_opts(ext), do: if(animated?(ext), do: "-coalesce ", else: "")

  # vips JPEG/WebP support a `Q=` save option; PNG/GIF are lossless so only strip metadata
  # (passing `Q=` to PNG would trigger lossy palette quantisation, which we don't want)
  defp vips_save_opts(ext, quality) when ext in ["jpg", "jpeg", "webp"],
    do: "[Q=#{quality},strip]"

  defp vips_save_opts(_ext, _quality), do: "[strip]"

  def video_image_thumbnail(filename, max_size, scrub_opts, waffle_file \\ %Waffle.File{}) do
    filename
    |> debug("thumbnail_video_run")

    with true <- choose_executable(:video, Image.Video),
         {:ok, %{fps: fps, frame_count: frame_count} = video} <-
           Image.Video.open(filename)
           #  video <- Image.Video.stream!(frame: scrub_frames..scrub_frames//2) # TODO?
           |> debug("thumbnail_video_open"),
         {:ok, image} <-
           Image.Video.image_from_video(video,
             frame: frame_to_scrub(fps, frame_count, scrub_opts)
           )
           |> debug("thumbnail_video_image") do
      temp_thumb = "#{Waffle.File.generate_temporary_path()}.jpg"

      image_resize_thumbnail(
        image,
        max_size,
        waffle_file,
        tmp_path: temp_thumb,
        crop: :attention,
        resize: :down
      )

      # image_save_temp_file(image, waffle_file, temp_thumb)
    else
      e ->
        IO.warn(inspect(e))
        error(e, "Could not generate a video thumbnail")
        nil
    end
  catch
    :exit, e ->
      error(e)
      nil

    e ->
      error(e)
      nil
  end

  def frame_to_scrub(fps, frame_count, scrub_opts) do
    percent = scrub_opts[:percent]
    scrub_frames = scrub_opts[:frames] || (scrub_opts[:seconds] || 5) * (fps || 30)

    cond do
      is_number(percent) and is_number(frame_count) ->
        Types.maybe_to_integer(frame_count / percent)

      scrub_frames < frame_count ->
        scrub_frames

      # frame_count > 35 -> frame_count-30
      is_number(frame_count) ->
        Types.maybe_to_integer(frame_count / 2)

      true ->
        1
    end
    |> debug("thumbnail_video_frame_to_scrub")
  end

  def image_resize_thumbnail(image, max_size, waffle_file \\ %Waffle.File{}, opts) do
    # TODO: return a Stream instead of creating a temp file: https://hexdocs.pm/image/Image.html#stream!/2
    # `tmp_path` is where to save, and `animated` whether to keep all the frames: neither is an option of `Image.thumbnail`, which refuses unknown ones
    {animated, opts} = Keyword.pop(opts, :animated, false)

    with true <- !!choose_executable(:thumbnail, Image),
         {:ok, source} <- image_source(image, animated),
         {:ok, image} <-
           Image.thumbnail(source, max_size, Keyword.delete(opts, :tmp_path)),
         {:ok, image} <- image_strip_metadata(image, animated) do
      image_save_temp_file(image, waffle_file, opts[:tmp_path])
    else
      false ->
        # TODO: cleanup the uploaded file if we won't be able to process it, to avoid filling up storage with unprocessable files
        if Config.env() == :test and System.get_env("CI") in @yes? do
          {:ok, waffle_file}
        else
          {:error,
           %Bonfire.Fail{
             code: :no_image_tool,
             message:
               l(
                 "No image processing tool available. Please ask the instance admins to install Vips and/or ImageMagick tools."
               ),
             status: 500
           }}
        end

      e ->
        error(e, "Could not create or save thumbnail")
        nil
    end
  catch
    :exit, e ->
      error(e)
      nil

    e ->
      error(e)
      nil
  end

  @doc "Whether resized images have all their metadata removed, rather than keeping the author's copyright and artist tags."
  def strip_author_metadata? do
    Config.get([:bonfire_files, :strip_author_metadata], true,
      name: l("Strip author metadata"),
      description: l("Also remove the copyright and artist tags when resizing an uploaded image")
    )
  end

  # an animated image is opened with all its pages, as one tall image that the thumbnailer cuts back into frames
  defp image_source(path, true) when is_binary(path), do: Image.open(path, pages: :all)
  defp image_source(image, _animated), do: {:ok, image}

  defp image_strip_metadata(image, animated \\ false)

  # the fields that tell the frames apart (their height, delays and loop count) stay, or the saved file would be one tall frame
  defp image_strip_metadata(image, true) do
    with {:ok, fields} <- Vix.Vips.Image.header_field_names(image) do
      Image.remove_metadata(image, fields -- @animation_fields)
    end
  end

  defp image_strip_metadata(image, false) do
    if strip_author_metadata?() do
      Image.remove_metadata(image)
    else
      Image.minimize_metadata(image)
    end
  end

  def image_save_temp_file(image, waffle_file \\ %Waffle.File{}, tmp_path \\ nil) do
    tmp_path = tmp_path || Waffle.File.generate_temporary_path(waffle_file.file_name)

    with {:ok, _} <-
           Image.write(image, tmp_path, image_save_opts())
           |> debug("thumbnail_video_write") do
      {:ok, %Waffle.File{waffle_file | path: tmp_path, is_tempfile?: true}}
    else
      e ->
        error(e, "Could not save image")
        nil
    end
  end

  # `minimize_file_size` strips every tag on save, so it is only safe when we are removing all metadata anyway: otherwise it would also throw away the copyright and artist that `image_strip_metadata/1` deliberately kept
  defp image_save_opts do
    if strip_author_metadata?() do
      [minimize_file_size: true, quality: image_quality()]
    else
      [quality: image_quality()]
    end
  end

  @doc """
  Returns the dominant color of an image (given as path, binary, or stream) as HEX value.

  `bins` is an integer number of color frequency bins the image is divided into. The default is 10.
  """
  def dominant_color(file_path_or_binary_or_stream, bins \\ 15, fallback \\ "#FFF8E7") do
    with true <- !!choose_executable(:dominant_color, Image),
         {:ok, img} <- Image.open(file_path_or_binary_or_stream),
         {:ok, rgb} <-
           Image.dominant_color(img, [{:bins, bins}]),
         {:ok, color} <- Image.Color.rgb_to_hex(rgb) do
      color
    else
      e ->
        error(e, "Could not calculate image color")
        debug(File.cwd())
        fallback
    end
  rescue
    e in MatchError ->
      error(e, "Could not calculate image color")
      fallback
  end

  @doc """
  Returns the pixel dimensions of an image (given as path, binary, or stream) as `{width, height}`, or `nil` if they can't be read.

  Uses the `Image`/vix header so it does not fully decode the image, making it cheap enough to call at render time as a lazy backfill.
  """
  def dimensions(file_path_or_binary_or_stream) do
    with true <- !!choose_executable(:dimensions, Image),
         {:ok, img} <- Image.open(file_path_or_binary_or_stream),
         width when is_integer(width) <- Image.width(img),
         height when is_integer(height) <- Image.height(img),
         true <- width > 0 and height > 0 do
      {width, height}
    else
      e ->
        error(e, "Could not read image dimensions")
        nil
    end
  rescue
    e ->
      error(e, "Could not read image dimensions")
      nil
  end

  @doc """
  The number of pixels an image declares in its header (width times height), or `nil` if that can't be read. Nothing is decoded: a few KB of PNG can declare billions of pixels, which is what a thumbnailer would then try to allocate.

  Reads it with the `Image`/vix header when that is available, else with `vipsheader`.
  """
  def declared_pixels(path) when is_binary(path) do
    case dimensions(path) do
      {width, height} -> width * height
      nil -> vips_header_pixels(path)
    end
  end

  def declared_pixels(_), do: nil

  defp vips_header_pixels(path) do
    with exe when is_binary(exe) <- choose_executable(:dimensions, "vipsheader"),
         width when is_integer(width) <- vips_header_field(exe, "width", path),
         height when is_integer(height) <- vips_header_field(exe, "height", path) do
      width * height
    else
      _ -> nil
    end
  end

  defp vips_header_field(exe, field, path) do
    with {out, 0} <- System.cmd(exe, ["-f", field, path], stderr_to_stdout: true),
         {number, ""} <- out |> String.trim() |> Integer.parse() do
      number
    else
      _ -> nil
    end
  end

  # catch an issue when trying to blur gifs
  def blur(path, final_path) when not is_nil(path) do
    format = "jpg"

    cond do
      choose_executable(:blur, "convert") ->
        Mogrify.open(path)
        # NOTE: since we're resizing an already resized thumnail, don't worry about cropping, stripping, etc
        |> Mogrify.resize("10%")
        |> Mogrify.custom("colors", "8")
        |> Mogrify.custom("depth", "8")
        |> Mogrify.custom("blur", "2x2")
        |> Mogrify.quality("20")
        |> Mogrify.format(format)
        # |> debug()
        |> Mogrify.save(path: final_path)
        |> Map.get(:path)

      choose_executable(:blur, "vips") ->
        with {_, 0} <-
               System.cmd("vips", ["resize", path, "#{final_path}", "0.10"]) do
          final_path
        end

      true ->
        nil
    end
  rescue
    e in File.CopyError ->
      error(e)
      nil
  end
end
