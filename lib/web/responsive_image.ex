defmodule Bonfire.Files.ResponsiveImage do
  @moduledoc """
  Resizes images at compile time (when possible) or runtime:

  ```
  use Bonfire.Files.ResponsiveImage

  ~H(<img src={compile_src("input.jpg", 300)} />)
  or
  ~H(<img srcset={compile_srcset("input.jpg", [300, 600, 900])} src={...} sizes="50vw" />)

  or for paths only known at runtime:
  ~H(<img src={src(my_image, 300)} />)
  or
  ~H(<img srcset={srcset(my_image, [300, 600, 900])} src={...} sizes="50vw" />)
  ```
  """

  defmacro __using__(_opts) do
    quote do
      import unquote(__MODULE__)
      Module.register_attribute(__MODULE__, :image, accumulate: true)
      @before_compile unquote(__MODULE__)
    end
  end

  defmacro compile_src(path, width) do
    Module.put_attribute(__CALLER__.module, :image, {path, width})

    quote do
      unquote(img_src(path, width))
    end
  end

  defmacro compile_srcset(path, widths) do
    for width <- widths, do: Module.put_attribute(__CALLER__.module, :image, {path, width})

    quote do
      unquote(img_src(path, widths))
    end
  end

  def src(path, width) do
    resize_timed({path, width})

    img_src(path, width)
  end

  def srcset(path, widths) do
    resize_timed(for width <- widths, do: {path, width})

    img_src(path, widths)
  end

  defmacro __before_compile__(_env) do
    Bonfire.Files.ResponsiveImage.resize_timed(Module.get_attribute(__CALLER__.module, :image))
  end

  def resize_timed(images) do
    {duration, _} =
      :timer.tc(fn ->
        resize(images)
      end)

    IO.puts("Image resize took #{duration / 1_000_000}s")
  end

  def resize(attr) when is_list(attr) do
    for {path, width} <- attr, do: resize(path, width)
  end

  def resize({path, width}) do
    resize(path, width)
  end

  def resize(path, width) do
    out_path = out_path(path, width)

    # TODO: move/reuse function in ImageEdit

    if not File.exists?(out_path) do
      IO.puts("Writing #{out_path}")
      out_path |> Path.dirname() |> File.mkdir_p!()

      # TODO: handle src path being a URI
      path
      |> in_path()
      |> Image.open!()
      |> then(&Image.resize!(&1, width / Image.width(&1)))
      |> Image.write!(out_path, quality: 90)
    end
  end

  defp without_ext(path), do: "#{Path.dirname(path)}/#{Path.basename(path, Path.extname(path))}"
  defp in_path(path), do: Path.join("priv/static/images/", path)

  defp img_src(path, widths) when is_list(widths),
    do: widths |> Enum.map(&"#{img_src(path, &1)} #{&1}w") |> Enum.join(", ")

  defp img_src(path, width), do: "/resized/#{without_ext(path)}_#{width}.avif"
  defp out_path(path, width), do: "priv/static#{img_src(path, width)}"
end
