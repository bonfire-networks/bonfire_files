defmodule Bonfire.Files.Image.Edit do
  import Untangle

  def image(filename, max_width, max_height) do
    cond do
      System.find_executable("vipsthumbnail") ->
        {:vipsthumbnail,
         fn input, output ->
           "#{input} --size #{max_width}x#{max_height} --linear --export-profile srgb -o #{output}[strip]"
           # |> info()
         end, Bonfire.Files.file_extension_only(filename)}

      System.find_executable("convert") ->
        {:convert,
         "-strip -thumbnail #{max_width}x#{max_height}> -limit area 10MB -limit disk 50MB"}

      true ->
        nil
    end
  end

  def thumbnail(filename) do
    # TODO: configurable
    max_size = 142

    cond do
      System.find_executable("vipsthumbnail") ->
        {:vipsthumbnail,
         fn input, output ->
           "#{input} --smartcrop attention -s #{max_size} --linear --export-profile srgb -o #{output}[strip]"
           # |> info()
         end, Bonfire.Files.file_extension_only(filename)}

      System.find_executable("convert") ->
        {:convert,
         "-strip -thumbnail #{max_size}x#{max_size}^ -gravity center -crop #{max_size}x#{max_size}+0+0 -limit area 10MB -limit disk 20MB"}

      true ->
        &thumbnail_image/2
        # nil
    end
  end

  def thumbnail_pdf(_filename) do
    # TODO: configurable
    max_size = 1024

    if System.find_executable("pdftocairo"),
      do:
        {:pdftocairo,
         fn original_path, new_path ->
           " -png -singlefile -scale-to #{max_size} #{original_path} #{String.slice(new_path, 0..-5)}"
         end, :png},
      else: :noaction
  catch
    :exit, e ->
      error(e)
      :noaction

    e ->
      error(e)
      :noaction
  end

  def thumbnail_image(_version, %{path: filename} = original_file) do
    # TODO: configurable
    max_size = 142

    # TODO: return a Stream instead of creating a temp file: https://hexdocs.pm/image/Image.html#stream!/2

    with {:ok, image} <- Image.thumbnail(filename, max_size, crop: :attention),
         tmp_path <- Waffle.File.generate_temporary_path(original_file),
         {:ok, _} <- Image.write(image, tmp_path) do
      {:ok, %Waffle.File{original_file | path: tmp_path, is_tempfile?: true}}
    else
      e ->
        error(e, "Could not create or save thumbnail")
        :noaction
    end
  catch
    :exit, e ->
      error(e)
      :noaction

    e ->
      error(e)
      :noaction
  end

  @doc """
  Returns the dominant color of an image (given as path, binary, or stream) as HEX value.

  `bins` is an integer number of color frequency bins the image is divided into. The default is 10.
  """
  def dominant_color(file_path_or_binary_or_stream, bins \\ 10, fallback \\ "#FFF8E7") do
    with {:ok, img} <- Image.open(file_path_or_binary_or_stream),
         {:ok, color} <-
           Image.dominant_color(img, [{:bins, bins}])
           |> Image.Color.rgb_to_hex() do
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

  def banner(filename, max_width, max_height) do
    cond do
      System.find_executable("vipsthumbnail") ->
        {:vipsthumbnail,
         fn input, output ->
           "#{input} --smartcrop attention --size #{max_width}x#{max_height} --linear --export-profile srgb -o #{output}[strip]"
           # |> info()
         end, Bonfire.Files.file_extension_only(filename)}

      System.find_executable("convert") ->
        {:convert,
         "-strip -thumbnail #{max_width}x#{max_height}> -limit area 10MB -limit disk 50MB"}

      true ->
        nil
    end
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
