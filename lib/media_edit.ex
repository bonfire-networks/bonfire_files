defmodule Bonfire.Files.MediaEdit do
  import Untangle
  # use Arrows
  alias Bonfire.Files
  alias Bonfire.Common.Extend
  alias Bonfire.Common.Types

  def image(filename, max_width, max_height) do
    ext = Files.file_extension_only(filename)

    max_size = "#{max_width}x#{max_height}"

    cond do
      ext not in ["jpg", "jpeg", "png", "gif", "webp"] ->
        # to avoid error `svgload: operation is blocked`
        nil

      System.find_executable("vipsthumbnail") ->
        {:vipsthumbnail,
         fn input, output ->
           "#{input} --size #{max_size} --linear --export-profile srgb -o #{output}[strip]"
           # |> info()
         end, ext}

      System.find_executable("convert") ->
        {:convert, "-strip -thumbnail #{max_size}> -limit area 10MB -limit disk 50MB"}

      true ->
        fn _version, %{path: filename} = waffle_file ->
          image_resize_thumbnail(filename, max_size, waffle_file)
        end
    end
  end

  def thumbnail(filename, max_size) do
    ext = Files.file_extension_only(filename)

    cond do
      ext not in ["jpg", "jpeg", "png", "gif", "webp"] ->
        # avoid error `svgload: operation is blocked`
        nil

      System.find_executable("vipsthumbnail") ->
        {:vipsthumbnail,
         fn input, output ->
           "#{input} --smartcrop attention -s #{max_size} --linear --export-profile srgb -o #{output}[strip]"
           # |> info()
         end, ext}

      System.find_executable("convert") ->
        {:convert,
         "-strip -thumbnail #{max_size}x#{max_size}^ -gravity center -crop #{max_size}x#{max_size}+0+0 -limit area 10MB -limit disk 20MB"}

      true ->
        fn _version, %{path: filename} = waffle_file ->
          image_resize_thumbnail(filename, max_size, waffle_file)
        end
    end
  end

  def thumbnail_video(filename, max_size, scrub_opts) do
    ext = Files.file_extension_only(filename)

    # TODO: convert in background rather than block publication (but federation would need to be triggered when file is ready)

    cond do
      System.find_executable("ffmpeg") ->
        {:ffmpeg,
         fn input, output ->
           "-hide_banner -i #{input} -frames:v 1 -vf thumbnail=150,scale=#{max_size} #{output}"
         end, "jpg"}

      # -frames:v 1: number of frames
      # -vf thumbnail=300: analyse N frames and pick most "significant" one
      # -vf scale=300: scale while preserving aspect ratio

      System.find_executable("ffmpegthumbnailer") ->
        {:ffmpegthumbnailer,
         fn input, output ->
           "-i #{input} -t #{scrub_opts[:percent]} -s #{max_size} -q 9 -o #{output}"
         end, "jpg"}

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

      Extend.module_available?(Image.Video) ->
        {fn _version, %{path: filename} = waffle_file ->
           video_image_thumbnail(filename, max_size, scrub_opts, waffle_file)
           |> IO.inspect(label: "thumbnail_video_ran")
         end, fn _version, _file -> "jpg" end}

      # System.find_executable("convert") ->
      #   {:convert,
      #    "[#{scrub*30}] -strip -thumbnail #{max_size}x#{max_size}^ -gravity center -crop #{max_size}x#{max_size}+0+0 -limit area 10MB -limit disk 20MB"}

      true ->
        nil
    end
    |> IO.inspect(label: "thumbnail_video")
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
    |> IO.inspect()
  end

  def thumbnail_pdf(_filename) do
    # TODO: configurable
    max_size = 1024

    cond do
      System.find_executable("pdftocairo") ->
        {:pdftocairo,
         fn original_path, new_path ->
           " -png -singlefile -scale-to #{max_size} #{original_path} #{String.slice(new_path, 0..-5//1)}"
         end, :png}

      System.find_executable("vips") ->
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

  def banner(filename, max_width, max_height) do
    ext = Bonfire.Files.file_extension_only(filename)

    max_size = "#{max_width}x#{max_height}"

    cond do
      ext not in ["jpg", "jpeg", "png", "gif", "webp"] ->
        # avoid error `svgload: operation is blocked`
        nil

      System.find_executable("vipsthumbnail") ->
        {:vipsthumbnail,
         fn input, output ->
           "#{input} --smartcrop attention --size #{max_size} --linear --export-profile srgb -o #{output}[strip]"
           # |> info()
         end, ext}

      System.find_executable("convert") ->
        {:convert, "-strip -thumbnail #{max_size}> -limit area 10MB -limit disk 50MB"}

      true ->
        fn _version, %{path: filename} = waffle_file ->
          image_resize_thumbnail(filename, max_size, waffle_file)
        end
    end
  end

  def video_image_thumbnail(filename, max_size, scrub_opts, waffle_file \\ %Waffle.File{}) do
    filename
    |> IO.inspect(label: "thumbnail_video_run")

    with true <- Extend.module_available?(Image.Video),
         {:ok, %{fps: fps, frame_count: frame_count} = video} <-
           Image.Video.open(filename)
           #  video <- Image.Video.stream!(frame: scrub_frames..scrub_frames//2) # TODO?
           |> IO.inspect(label: "thumbnail_video_open"),
         {:ok, image} <-
           Image.Video.image_from_video(video,
             frame: frame_to_scrub(fps, frame_count, scrub_opts)
           )
           |> IO.inspect(label: "thumbnail_video_image") do
      temp_thumb = "#{Waffle.File.generate_temporary_path()}.jpg"

      image_resize_thumbnail(
        image,
        max_size,
        waffle_file,
        temp_thumb
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
    |> IO.inspect(label: "thumbnail_video_frame_to_scrub")
  end

  def image_resize_thumbnail(image, max_size, waffle_file \\ %Waffle.File{}, tmp_path \\ nil) do
    # TODO: return a Stream instead of creating a temp file: https://hexdocs.pm/image/Image.html#stream!/2
    with true <- Extend.module_available?(Image),
         {:ok, image} <- Image.thumbnail(image, max_size, crop: :attention) do
      image_save_temp_file(image, waffle_file, tmp_path)
    else
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

  def image_save_temp_file(image, waffle_file \\ %Waffle.File{}, tmp_path \\ nil) do
    tmp_path = tmp_path || Waffle.File.generate_temporary_path(waffle_file.file_name)

    with {:ok, _} <-
           Image.write(image, tmp_path, minimize_file_size: true)
           |> IO.inspect(label: "thumbnail_video_write") do
      {:ok, %Waffle.File{waffle_file | path: tmp_path, is_tempfile?: true}}
    else
      e ->
        error(e, "Could not save image")
        nil
    end
  end

  @doc """
  Returns the dominant color of an image (given as path, binary, or stream) as HEX value.

  `bins` is an integer number of color frequency bins the image is divided into. The default is 10.
  """
  def dominant_color(file_path_or_binary_or_stream, bins \\ 15, fallback \\ "#FFF8E7") do
    with true <- Extend.module_available?(Image),
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

  # catch an issue when trying to blur gifs
  def blur(path, final_path) when not is_nil(path) do
    format = "jpg"

    cond do
      System.find_executable("convert") ->
        Mogrify.open(path)
        # NOTE: since we're resizing an already resized thumnail, don't worry about cropping, stripping, etc
        |> Mogrify.resize("10%")
        |> Mogrify.custom("colors", "8")
        |> Mogrify.custom("depth", "8")
        |> Mogrify.custom("blur", "2x2")
        |> Mogrify.quality("20")
        |> Mogrify.format(format)
        # |> IO.inspect
        |> Mogrify.save(path: final_path)
        |> Map.get(:path)

      System.find_executable("vips") ->
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
