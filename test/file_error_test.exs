# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Test.FileErrors do
  use Bonfire.DataCase, async: false
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

  @doc """
  This macro temporarily replaces an environment variable for testing purposes.
  Since the environment is global to the process, this is not async safe and might interfere with other tests if run in parallel.
  """
  defmacro with_var(app, key, value, do: expression) do
    quote do
      {app, key, value} = {unquote(app), unquote(key), unquote(value)}
      old_value = Application.get_env(app, key)
      Application.put_env(app, key, value)
      result = unquote(expression)
      Application.put_env(app, key, old_value)

      result
    end
  end

  describe "file size check" do
    test "file is too big" do
      max_size = 0.0001

      with_var(:bonfire_files, :max_user_images_file_size, 0.0001) do
        {:error, %FileDenied{message: message, code: code}} =
          Files.upload(ImageUploader, fake_user!(), icon_file())

        assert message == "This file exceeds the maximum upload size 100 B"
        assert code == "file_denied"
      end
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
