# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ImagePixelCapTest do
  @moduledoc """
  An uploaded image that declares an enormous size in pixels is refused before anything decodes it: a few hundred KB of PNG can inflate to gigabytes of pixels in the thumbnailer. Needs `vipsthumbnail` (it is the tool whose branches are checked), so the tests are left out where it is not installed.
  """
  use Bonfire.DataCase, async: true
  @moduletag :backend

  import Bonfire.Files.Simulation

  alias Bonfire.Files.ImageUploader

  @side 30_000

  # a valid 1-bit grayscale PNG of `@side` x `@side` pixels, all black: about 110 KB of file for 900 million pixels
  defp huge_png_file do
    row = <<0, 0::size(@side)>>
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 9)

    data =
      for _ <- 1..div(@side, 100), reduce: [] do
        acc -> [acc, :zlib.deflate(z, List.duplicate(row, 100))]
      end

    idat = IO.iodata_to_binary([data, :zlib.deflate(z, [], :finish)])
    :ok = :zlib.deflateEnd(z)
    :zlib.close(z)

    ihdr = <<@side::32, @side::32, 1, 0, 0, 0, 0>>

    png =
      IO.iodata_to_binary([
        <<137, 80, 78, 71, 13, 10, 26, 10>>,
        chunk("IHDR", ihdr),
        chunk("IDAT", idat),
        chunk("IEND", <<>>)
      ])

    path = Path.join(System.tmp_dir!(), "huge_#{System.unique_integer([:positive])}.png")
    File.write!(path, png)
    on_exit(fn -> File.rm(path) end)
    %{path: path, filename: "huge.png"}
  end

  defp chunk(type, data),
    do: [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]

  defp copy_of_fixture do
    source = image_file()
    path = Path.join(System.tmp_dir!(), "copy_#{System.unique_integer([:positive])}.png")
    File.cp!(source.path, path)
    on_exit(fn -> File.rm(path) end)
    %{path: path, filename: source.filename}
  end

  if System.find_executable("vipsthumbnail") do
    setup do
      Process.put(
        [:bonfire_files, :choose_executable, "vipsthumbnail"],
        System.find_executable("vipsthumbnail")
      )

      Process.put([:bonfire_files, :choose_executable, "convert"], false)
      Process.put([:bonfire_files, :choose_executable, Image], false)
      :ok
    end

    test "control: an ordinary 600x800 image is accepted and thumbnailed" do
      assert {:ok, _upload} = fake_upload(copy_of_fixture(), ImageUploader)
    end

    test "an image declaring 30000x30000 pixels is refused" do
      assert {:error, _} = fake_upload(huge_png_file(), ImageUploader)
    end
  end
end
