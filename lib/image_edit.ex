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
        nil
    end
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
  def blur(path, final_path) do
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
