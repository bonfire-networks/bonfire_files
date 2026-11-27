# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.BlockUntrustedLoadersTest do
  @moduledoc """
  Boot sets `VIPS_BLOCK_UNTRUSTED=TRUE` (unless an admin set it) so every vips subprocess refuses libvips' untrusted loaders.
  """
  use ExUnit.Case, async: false
  @moduletag :backend

  alias Bonfire.Files.MediaEdit

  @var "VIPS_BLOCK_UNTRUSTED"
  @anim Path.expand("fixtures/formats/anim.avif", __DIR__)

  setup do
    original = System.get_env(@var)

    on_exit(fn ->
      if original, do: System.put_env(@var, original), else: System.delete_env(@var)
    end)
  end

  test "sets it to TRUE when unset" do
    System.delete_env(@var)
    assert :ok = MediaEdit.block_untrusted_loaders()
    assert System.get_env(@var) == "TRUE"
  end

  test "leaves an admin's value alone" do
    System.put_env(@var, "FALSE")
    MediaEdit.block_untrusted_loaders()
    assert System.get_env(@var) == "FALSE"
  end

  if System.find_executable("vipsthumbnail") do
    test "vipsthumbnail can't open an animated AVIF (ImageMagick loader only) once set" do
      dir = Path.join(System.tmp_dir!(), "vips_block_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      src = Path.join(dir, "anim.avif")
      File.cp!(@anim, src)
      out = Path.join(dir, "out.webp")

      run = fn ->
        File.rm(out)

        System.cmd("vipsthumbnail", [src <> "[n=-1]", "--size", "400x400>", "-o", out],
          stderr_to_stdout: true
        )
        |> elem(1)
      end

      System.delete_env(@var)
      MediaEdit.block_untrusted_loaders()
      assert run.() != 0
      File.rm_rf!(dir)
    end
  end
end
