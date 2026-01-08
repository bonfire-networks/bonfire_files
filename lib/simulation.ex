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
  @pdf_file %{
    path: Path.expand("../test/fixtures/doc.pdf", __DIR__),
    filename: "doc.pdf"
  }
  @audio_file %{
    path: Path.expand("../test/fixtures/spaghetti.mp3", __DIR__),
    filename: "spaghetti.mp3"
  }
  @video_file %{
    path: Path.expand("../test/fixtures/spaghetti.mp4", __DIR__),
    filename: "spaghetti.mp4"
  }
  def icon_file, do: @icon_file
  def image_file, do: @image_file
  def text_file, do: @text_file
  def pdf_file, do: @pdf_file
  def audio_file, do: @audio_file
  def video_file, do: @video_file

  def fake_upload(file, upload_def \\ nil, creator \\ nil) do
    creator = creator || fake_user!()

    upload_def =
      upload_def ||
        Faker.Util.pick([IconUploader, ImageUploader, DocumentUploader])

    Files.upload(upload_def, creator, file, %{})
  end

  def fake_user_with_avatar!(user \\ nil) do
    me = user || fake_user!()

    {:ok, upload} = Files.upload(IconUploader, me, icon_file())

    url = Bonfire.Common.Media.avatar_url(upload)

    path =
      if path = Files.local_path(IconUploader, upload) do
        File.exists?(path) && path
      end

    {:ok, me} = Bonfire.Me.Profiles.set_profile_image(:icon, me, upload)

    %{user: me, upload: upload, path: path, url: url}
  end

  def geometry(path) do
    {identify, 0} = System.cmd("identify", ["-verbose", path], stderr_to_stdout: true)

    Enum.at(Regex.run(~r/Geometry: ([^+]*)/, identify), 1)
  end

  def cleanup(path) do
    File.rm(path)
  end
end
