defmodule Bonfire.Files.Image.Edit do
  import Where

  def maybe_blur(path, final_path, width \\ 32, height \\ 32) do
    format = "jpg"

    if System.find_executable("convert"), do: Mogrify.open(path)
    # NOTE: since we're resizing an already resized thumnail, don't worry about cropping, stripping, etc
    |> Mogrify.resize("#{width}x#{height}")
    |> Mogrify.custom("colors", "16")
    |> Mogrify.custom("depth", "8")
    |> Mogrify.custom("blur", "2x2")
    |> Mogrify.quality("50")
    |> Mogrify.format(format)
    # |> IO.inspect
    |> Mogrify.save(path: final_path)
    |> Map.get(:path)
  end

  def thumbnail(filename) do
    max_size = 142 # TODO: configurable
    cond do
      System.find_executable("vipsthumbnail") ->
        {:vipsthumbnail,
        fn(input, output) ->
          "#{input} --smartcrop attention -s #{max_size} --linear --export-profile srgb -o #{output}[strip]"
          |> info()
        end,
        Bonfire.Files.file_extension(filename)
        }

      System.find_executable("convert") ->
        {:convert, "-strip -thumbnail #{max_size}x#{max_size}^ -gravity center -crop #{max_size}x#{max_size}+0+0 -limit area 50MB -limit disk 1MB"}
    end
  end

  def banner(filename) do
    # TODO: configurable
    max_width = 580
    max_height = 700
    if System.find_executable("convert"), do: {:convert, "-strip -thumbnail #{max_width}x#{max_height}> -limit area 3MB -limit disk 20MB"}
  end

end
