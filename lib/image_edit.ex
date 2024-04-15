defmodule Bonfire.Files.Image.Edit do
  import Untangle
  alias Bonfire.Files
  alias Bonfire.Common.Extend

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

  def thumbnail_pdf(_filename) do
    # TODO: configurable
    max_size = 1024

    cond do
      System.find_executable("pdftocairo") ->
        {:pdftocairo,
         fn original_path, new_path ->
           " -png -singlefile -scale-to #{max_size} #{original_path} #{String.slice(new_path, 0..-5)}"
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

  def image_resize_thumbnail(filename, max_size, waffle_file \\ %Waffle.File{}) do
    # TODO: return a Stream instead of creating a temp file: https://hexdocs.pm/image/Image.html#stream!/2
    with true <- Extend.module_exists?(Image),
         {:ok, image} <- Image.thumbnail(filename, max_size, crop: :attention),
         tmp_path <- Waffle.File.generate_temporary_path(waffle_file),
         {:ok, _} <- Image.write(image, tmp_path) do
      {:ok, %Waffle.File{waffle_file | path: tmp_path, is_tempfile?: true}}
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

  @doc """
  Returns the dominant color of an image (given as path, binary, or stream) as HEX value.

  `bins` is an integer number of color frequency bins the image is divided into. The default is 10.
  """
  def dominant_color(file_path_or_binary_or_stream, bins \\ 15, fallback \\ "#FFF8E7") do
    with true <- Extend.module_exists?(Image),
         {:ok, img} <- Image.open(file_path_or_binary_or_stream),
         {:ok, color} <-
           Image.dominant_color(img, [{:bins, bins}])
           |> debug()
           |> Image.Color.rgb_to_hex()
           |> debug() do
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
