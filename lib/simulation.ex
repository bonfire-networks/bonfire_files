defmodule Bonfire.Files.Simulation do
  #   import Bonfire.Common.Simulation
  import Bonfire.UI.Common.Testing.Helpers

  alias Bonfire.Files

  alias Bonfire.Files.DocumentUploader
  alias Bonfire.Files.FileDenied
  alias Bonfire.Files.IconUploader
  alias Bonfire.Files.ImageUploader
  alias Bonfire.Files.Media

  @icon_file %{
    path: Path.expand("../test/fixtures/150.png", __DIR__),
    filename: "150.png"
  }
  @image_file %{
    path: Path.expand("../test/fixtures/600x800.png", __DIR__),
    filename: "600x800.png"
  }
  @text_file %{
    path: Path.expand("../test/fixtures/text.txt", __DIR__),
    filename: "text.txt"
  }
  def icon_file, do: @icon_file
  def image_file, do: @image_file
  def text_file, do: @text_file

  def fake_upload(file, upload_def \\ nil) do
    user = fake_user!()

    upload_def =
      upload_def ||
        Faker.Util.pick([IconUploader, ImageUploader, DocumentUploader])

    Files.upload(upload_def, user, file, %{})
  end

  def geometry(path) do
    {identify, 0} = System.cmd("identify", ["-verbose", path], stderr_to_stdout: true)

    Enum.at(Regex.run(~r/Geometry: ([^+]*)/, identify), 1)
  end

  def cleanup(path) do
    File.rm(path)
  end
end
