# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ApplyTransformTest do
  use Bonfire.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Files.MediaEdit

  @fixture Path.expand("fixtures/150.png", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "apply_transform_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "in.png")
    File.cp!(@fixture, path)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, wf: %Waffle.File{path: path, file_name: "in.png"}}
  end

  test ":noaction gives the file back untouched", %{wf: file} do
    assert {:ok, ^file} = MediaEdit.apply_transform(:noaction, file)
  end

  test ":skip gives no file", %{wf: file} do
    assert {:ok, nil} = MediaEdit.apply_transform(:skip, file)
  end

  test "nil (no tool could make a transform) gives no file", %{wf: file} do
    assert {:ok, nil} = MediaEdit.apply_transform(nil, file)
  end

  test "a 2-arity function is called with the version and the file", %{wf: file} do
    fun = fn version, f -> {:ok, %{f | file_name: "#{version}.png"}} end
    assert {:ok, %{file_name: "default.png"}} = MediaEdit.apply_transform(fun, file)
    assert {:ok, %{file_name: "default.png"}} = MediaEdit.apply_transform({fun, :png}, file)
  end

  if System.find_executable("convert") do
    test "{cmd, args} runs the tool and gives the new file", %{wf: file} do
      assert {:ok, %Waffle.File{path: out}} =
               MediaEdit.apply_transform({:convert, "-resize 50x50"}, file)

      assert out != file.path
      assert File.exists?(out)
    end

    test "{cmd, args, ext} gives a file with that extension", %{wf: file} do
      assert {:ok, %Waffle.File{path: out}} =
               MediaEdit.apply_transform({:convert, "-resize 50x50", "jpg"}, file)

      assert Path.extname(out) == ".jpg"
      assert File.exists?(out)
    end
  end
end
