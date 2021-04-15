# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.FilesTest do
  use Bonfire.DataCase, async: true

  alias Bonfire.Common.Simulation
  alias Bonfire.Files
  alias Bonfire.Files.Storage

  # FIXME: path
  @image_file %{path: "forks/bonfire_files/test/images/150.png", filename: "150.png"}

  def fake_upload(file) do
    user = fake_user!()

    upload_def =
      Faker.Util.pick([
        Bonfire.Files.IconUploader,
        Bonfire.Files.ImageUploader,
        Bonfire.Files.ResourceUploader
      ])

    Files.upload(upload_def, user, file, %{})
  end

  # describe "list_by_parent" do
  #   test "returns a list of uploads for a parent" do
  #     uploads =
  #       for _ <- 1..5 do
  #         user = fake_user!()

  #         {:ok, upload} =
  #           Files.upload(Bonfire.Files.IconUploader, user, @image_file, %{})

  #         upload
  #       end

  #     assert Enum.count(uploads) == Enum.count(Files.list_by_parent(comm))
  #   end
  # end

  describe "one" do
    test "returns an upload for an existing ID" do
      assert {:ok, original_upload} = fake_upload(@image_file)
      assert {:ok, fetched_upload} = Files.one(id: original_upload.id)
      assert original_upload.id == fetched_upload.id
      assert original_upload.content_upload.id == fetched_upload.content_upload.id
    end

    test "fails when given a missing ID" do
      assert {:error, :not_found} = Files.one(id: Simulation.ulid())
    end
  end

  describe "upload" do
    test "creates a file upload" do
      assert {:ok, upload} = fake_upload(@image_file)
      assert upload.media_type == "image/png"
      assert upload.content_upload.path
      assert upload.content_upload.size
    end

    test "fails when the file has a disallowed extension" do
      file = %{path: "test/fixtures/not-a-virus.exe", filename: "not-a-virus.exe"}
      assert {:error, :extension_denied} = fake_upload(file)
    end

    test "fails when the upload is a missing file" do
      file = %{path: "missing.gif", filename: "missing.gif"}
      assert {:error, :enoent} = fake_upload(file)
    end
  end

  describe "remote_url" do
    test "returns the remote URL for an existing upload" do
      assert {:ok, upload} = fake_upload(@image_file)
      assert {:ok, url} = Files.remote_url(upload)

      uri = URI.parse(url)
      assert uri.scheme
      assert uri.host
      assert uri.path
    end
  end

  describe "soft_delete" do
    test "updates the deletion date of the upload" do
      assert {:ok, upload} = fake_upload(@image_file)
      refute upload.deleted_at
      assert {:ok, deleted_upload} = Files.soft_delete(upload)
      assert deleted_upload.deleted_at
      # file should still be available
      assert {:ok, _} = Storage.remote_url(upload.content_upload.path)
    end
  end

  describe "hard_delete" do
    test "removes the upload, including files" do
      assert {:ok, upload} = fake_upload(@image_file)
      assert :ok = Files.hard_delete(upload)
      assert {:error, :enoent} = Storage.remote_url(upload.content_upload.path)
    end
  end
end
