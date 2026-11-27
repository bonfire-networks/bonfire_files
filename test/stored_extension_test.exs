# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.StoredExtensionTest do
  @moduledoc """
  A new upload is stored under the extension of the type found in its bytes, not the one in the name the client gave it: a JPEG named `photo`, `photo.jpe` or `photo.jfif` is stored as `<id>.jpg`, and a PNG named `x.jpg` as `<id>.png`. The resize and strip tools choose their output format from the stored name, so a mismatch leaves a file with its location in it, or no tool able to save it.

  Fixtures in `test/fixtures/gps/` all embed 48.8584 N, 2.2945 E.
  """
  use Bonfire.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Files
  alias Bonfire.Files.{BannerUploader, IconUploader, ImageUploader, InstanceIconUploader}

  @fixtures Path.expand("fixtures/gps", __DIR__)

  # the resize tool is picked at runtime by `MediaEdit.choose_executable/2`: force each branch in turn
  @tool_branches [
    {"vipsthumbnail only", [{"vipsthumbnail", true}, {"convert", false}, {Image, false}]},
    {"convert only", [{"vipsthumbnail", false}, {"convert", true}, {Image, false}]},
    {"Image library only", [{"vipsthumbnail", false}, {"convert", false}, {Image, true}]}
  ]

  if System.find_executable("exiftool") do
    for {branch, tools} <- @tool_branches,
        uploader <- [ImageUploader, IconUploader, BannerUploader, InstanceIconUploader],
        client_name <- ["photo", "photo.jpe", "photo.jfif"] do
      test "a JPEG named #{inspect(client_name)} is stored as .jpg with no GPS, with #{branch}, via #{inspect(uploader)}" do
        for {name, val} <- unquote(Macro.escape(tools)),
            do: Process.put([:bonfire_files, :choose_executable, name], val)

        creator = fake_user!()
        path = Path.join(@fixtures, "gps.jpg")

        assert {:ok, upload} =
                 Files.upload(unquote(uploader), creator, %{path: path}, %{
                   client_name: unquote(client_name)
                 })

        stored = stored_files(creator)
        assert stored != []
        assert Enum.all?(stored, &(Path.extname(&1) == ".jpg")), inspect(stored)

        assert Files.remote_url(nil, upload, :default) |> String.ends_with?(".jpg")

        leaks = for f <- stored, leak = gps_leak(f), do: {Path.relative_to_cwd(f), leak}
        assert leaks == [], inspect(leaks)
      end
    end
  end

  test "a PNG named x.jpg is stored as .png" do
    creator = fake_user!()
    path = Path.join(@fixtures, "gps.png")

    assert {:ok, upload} =
             Files.upload(ImageUploader, creator, %{path: path}, %{client_name: "x.jpg"})

    stored = stored_files(creator)
    assert stored != []
    assert Enum.all?(stored, &(Path.extname(&1) == ".png")), inspect(stored)
    assert Files.remote_url(nil, upload, :default) |> String.ends_with?(".png")
  end

  test "a JPEG named photo.jpg keeps .jpg (control)" do
    creator = fake_user!()
    path = Path.join(@fixtures, "gps.jpg")

    assert {:ok, upload} =
             Files.upload(ImageUploader, creator, %{path: path}, %{client_name: "photo.jpg"})

    assert Enum.all?(stored_files(creator), &(Path.extname(&1) == ".jpg"))
    assert Files.remote_url(nil, upload, :default) |> String.ends_with?(".jpg")
  end

  test "a JPEG named photo.jpeg keeps .jpeg (control: a known extension of its type)" do
    creator = fake_user!()
    path = Path.join(@fixtures, "gps.jpg")

    assert {:ok, upload} =
             Files.upload(ImageUploader, creator, %{path: path}, %{client_name: "photo.jpeg"})

    assert Enum.all?(stored_files(creator), &(Path.extname(&1) == ".jpeg"))
    assert Files.remote_url(nil, upload, :default) |> String.ends_with?(".jpeg")
  end

  test "a PDF named report.pdf keeps .pdf (control: a type that is not an image)" do
    creator = fake_user!()
    path = Path.join(@fixtures, "clean.pdf")

    assert {:ok, upload} =
             Files.upload(Bonfire.Files.DocumentUploader, creator, %{path: path}, %{
               client_name: "report.pdf"
             })

    # the thumbnail of a PDF is an image, stored beside it
    assert Enum.any?(stored_files(creator), &(Path.extname(&1) == ".pdf"))
    assert Files.remote_url(nil, upload, :default) |> String.ends_with?(".pdf")
  end

  defp stored_files(creator) do
    Path.wildcard("data/uploads/#{creator.id}/**/*")
    |> Enum.filter(&File.regular?/1)
  end

  defp gps_leak(path) do
    {out, _} = System.cmd("exiftool", ["-a", "-G1", "-s", "-ee", path], stderr_to_stdout: true)

    tags =
      out
      |> String.split("\n", trim: true)
      # the `System` group has the file's own name, whose random id can spell "GPS"
      |> Enum.reject(&String.starts_with?(&1, "[System]"))
      |> Enum.filter(&(&1 =~ ~r/GPS|Location|Coordinates/i))

    bin = File.read!(path)

    raw =
      Enum.filter(
        ["48.8584", "48,51.504", "+48.8584+002.2945"],
        &String.contains?(bin, &1)
      )

    if tags == [] and raw == [], do: nil, else: %{tags: tags, raw: raw}
  end
end
