# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Test do
  use Bonfire.DataCase, async: true
  @moduletag :backend

  import Bonfire.Files.Simulation

  alias Bonfire.Common.Simulation
  alias Bonfire.Files

  alias Bonfire.Files.DocumentUploader
  alias Bonfire.Files.FileDenied
  alias Bonfire.Files.IconUploader
  alias Bonfire.Files.ImageUploader
  alias Bonfire.Files.Media

  # describe "list_by_parent" do
  #   test "returns a list of uploads for a parent" do
  #     uploads =
  #       for _ <- 1..5 do
  #         creator = fake_user!()

  #         {:ok, upload} = 
  #           Files.upload(Bonfire.Files.IconUploader, creator, icon_file(), %{})

  #         upload
  #       end 

  #     assert Enum.count(uploads) == Enum.count(Files.list_by_parent(comm))
  #   end
  # end

  describe "one" do
    test "returns an upload for an existing ID" do
      assert {:ok, original_upload} = fake_upload(icon_file())
      assert {:ok, fetched_upload} = Media.one(id: original_upload.id)
      assert original_upload.id == fetched_upload.id
    end

    test "fails when given a missing ID" do
      assert {:error, :not_found} = Media.one(id: Simulation.ulid())
    end
  end

  describe "upload" do
    test "creates a file upload" do
      assert {:ok, upload} = fake_upload(icon_file())
      assert upload.media_type == "image/png"
      assert upload.path
      assert upload.size
    end

    test "fails when the file is a disallowed type" do
      # FIXME: path
      file = %{
        path: Path.expand("fixtures/not-a-virus.exe", __DIR__),
        filename: "not-a-virus.exe"
      }

      assert {:error, %FileDenied{}} = Files.upload(IconUploader, fake_user!(), file)
    end

    test "fails when the upload is a missing file" do
      file = %{path: "missing.gif", filename: "missing.gif"}
      assert {:error, _} = fake_upload(file)
    end
  end

  describe "remote_url" do
    test "returns the remote URL for an upload" do
      assert {:ok, upload} = Files.upload(DocumentUploader, fake_user!(), text_file())

      assert url = Files.remote_url(DocumentUploader, upload)

      uri = URI.parse(url)
      # assert uri.scheme 
      # assert uri.host
      assert uri.path =~ "/docs/"
    end
  end

  describe "soft_delete" do
    test "updates the deletion date of the upload, leaves files in place" do
      assert {:ok, upload} = Files.upload(IconUploader, fake_user!(), icon_file())

      assert path = Files.local_path(DocumentUploader, upload)
      assert File.exists?(path)

      refute upload.deleted_at
      assert {:ok, deleted_upload} = Media.soft_delete(upload)
      assert deleted_upload.deleted_at
      assert File.exists?(path)
    end
  end

  describe "hard_delete" do
    test "removes the upload, including files" do
      assert {:ok, upload} = Files.upload(ImageUploader, fake_user!(), icon_file())

      assert path = Files.local_path(ImageUploader, upload)
      assert File.exists?(path)

      assert {:ok, _} = Media.hard_delete(ImageUploader, upload)
      refute File.exists?(path)
    end
  end
end
