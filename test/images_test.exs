# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ImagesTest do
  use Bonfire.DataCase, async: true

  alias Bonfire.Common.Simulation
  alias Bonfire.Files

  alias Bonfire.Files.DocumentUploader
  alias Bonfire.Files.FileDenied
  alias Bonfire.Files.IconUploader
  alias Bonfire.Files.ImageUploader
  alias Bonfire.Files.Media

  # FIXME: path
  @icon_file %{
    path: Path.expand("fixtures/150.png", __DIR__),
    filename: "150.png"
  }
  @image_file %{
    path: Path.expand("fixtures/600x800.png", __DIR__),
    filename: "600x800.png"
  }
  @text_file %{
    path: Path.expand("fixtures/text.txt", __DIR__),
    filename: "text.txt"
  }

  def fake_upload(file, upload_def \\ nil) do
    user = fake_user!()

    upload_def =
      upload_def ||
        Faker.Util.pick([IconUploader, ImageUploader, DocumentUploader])

    Files.upload(upload_def, user, file, %{})
  end

  defp geometry(path) do
    {identify, 0} = System.cmd("identify", ["-verbose", path], stderr_to_stdout: true)

    Enum.at(Regex.run(~r/Geometry: ([^+]*)/, identify), 1)
  end

  defp cleanup(path) do
    File.rm(path)
  end

  describe "upload" do
    test "creates transformed versions for icons" do
      assert {:ok, upload} = fake_upload(@icon_file, IconUploader)

      if !System.get_env("CI") do
        # resized version(s)
        assert "142x142" ==
                 IconUploader.remote_url(upload)
                 |> String.slice(1, 10000)
                 |> geometry()

        # assert "48x48" == IconUploader.remote_url(upload, :small) |> String.slice(1, 10000) |> geometry()

        # original file untouched # TODO?
        # assert "150x150" == IconUploader.remote_url(upload, :original) |> String.slice(1, 10000) |> geometry()
      end
    end

    test "creates a transformed version for images" do
      assert {:ok, upload} = fake_upload(@image_file, ImageUploader)

      if !System.get_env("CI") do
        w =
          Bonfire.Common.Config.get_ext(
            :bonfire_files,
            [__MODULE__, :max_width],
            580
          )

        h =
          Bonfire.Common.Config.get_ext(
            :bonfire_files,
            [__MODULE__, :max_height],
            700
          )

        # resized version
        assert "525x#{h}" ==
                 ImageUploader.remote_url(upload)
                 |> String.slice(1, 10000)
                 |> geometry()

        # original file untouched # TODO?
        # assert "600x800" == ImageUploader.remote_url(upload, :original) |> String.slice(1, 10000) |> geometry()
      end
    end
  end
end
