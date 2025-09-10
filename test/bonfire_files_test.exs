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
  alias Bonfire.Files.EmojiUploader

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
    test "fails when given a missing ID" do
      assert {:error, :not_found} = Media.one(id: Simulation.uid())
    end
  end

  describe "upload" do
    test "creates a file upload" do
      assert {:ok, upload} = fake_upload(icon_file())
      assert upload.media_type == "image/png"
      assert upload.path || Bonfire.Common.Media.media_url(upload)
      assert upload.size

      assert {:ok, fetched_upload} = Media.one(id: upload.id)
      assert upload.id == fetched_upload.id
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

    test "can define a custom emoji" do
      me = fake_user!()

      label = "test custom emoji"
      shortcode = ":test:"

      {:ok, context} = Bonfire.Files.EmojiUploader.add_emoji(me, icon_file(), label, shortcode)
      me = current_user(context)

      assert emoji =
               Bonfire.Common.Settings.get([:custom_emoji, shortcode], nil, me)

      #  |> debug("emoji")

      assert File.exists?(String.trim_leading(emoji[:url] || "", "/")) or
               emoji[:url] =~ "/files/redir/" or
               Bonfire.Common.Media.emoji_url(emoji)
    end
  end

  describe "remote_url" do
    test "returns the remote URL for an upload" do
      assert {:ok, upload} = Files.upload(DocumentUploader, fake_user!(), text_file())

      assert url = Files.remote_url(DocumentUploader, upload)
      assert url =~ "/docs/"

      assert url =
               Files.remote_url(DocumentUploader, upload, nil, permanent: true)
               |> IO.inspect(label: "upload redir url")

      assert url =~ "/files/redir/"

      # Bonfire.Files.Web.UploadRedirectController.maybe_redirect_url(url, DocumentUploader.storage())
    end
  end

  describe "soft_delete" do
    test "updates the deletion date of the upload, leaves files in place" do
      assert {:ok, upload} = Files.upload(IconUploader, fake_user!(), icon_file())

      if path = Files.local_path(IconUploader, upload) do
        assert File.exists?(path)
      end || assert Bonfire.Common.Media.avatar_url(upload)

      refute upload.deleted_at
      assert {:ok, deleted_upload} = Media.soft_delete(upload)
      assert deleted_upload.deleted_at

      if path = Files.local_path(IconUploader, upload) do
        assert File.exists?(path)
      end

      # assert Bonfire.Common.Media.media_url(upload)
    end
  end

  describe "hard_delete" do
    test "removes the upload, including files" do
      assert {:ok, upload} = Files.upload(ImageUploader, fake_user!(), icon_file())

      if path = Files.local_path(ImageUploader, upload) do
        assert File.exists?(path)
        true
      end || assert Bonfire.Common.Media.image_url(upload)

      assert {:ok, _} = Media.hard_delete(ImageUploader, upload)

      if path = Files.local_path(ImageUploader, upload) do
        refute File.exists?(path)
      end

      assert {:error, _} = Media.one(id: upload.id)
      # refute Bonfire.Common.Media.image_url(upload)
    end
  end
end
