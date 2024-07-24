# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Test.FileErrors do
  use Bonfire.DataCase, async: true
  @moduletag :backend

  import Bonfire.Files.Simulation

  alias Bonfire.Files.VideoUploader
  alias Bonfire.Files.Definition
  alias Bonfire.Common.Simulation
  alias Bonfire.Files

  alias Bonfire.Files.DocumentUploader
  alias Bonfire.Files.FileDenied
  alias Bonfire.Files.IconUploader
  alias Bonfire.Files.ImageUploader
  alias Bonfire.Files.Media

  describe "file size check" do
    setup do
      Process.put([:bonfire_files, :max_user_images_file_size], 0.0001)
      on_exit(fn -> Process.delete([:bonfire_files, :max_user_images_file_size]) end)
    end

    test "file is too big" do
      {:error, %FileDenied{message: message, code: code}} =
        Files.upload(ImageUploader, fake_user!(), icon_file())

      assert message == "This file exceeds the maximum upload size 100 B"
      assert code == "file_denied"
    end
  end

  describe "media type check" do
    test "file is wrong media type" do
      {:error, %FileDenied{message: message, code: code}} =
        Files.upload(VideoUploader, fake_user!(), icon_file())

      assert message == "Files with the format of image/png are not allowed"
      assert code == "file_denied"
    end
  end
end
