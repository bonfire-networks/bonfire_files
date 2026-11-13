# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.LocalAttachmentTest do
  @moduledoc """
  An importer that holds the file itself (a picture inside an account archive) hands it over together with the AS2 attachment that described it, and gets the same Media a remote attachment would give, alt text included, but stored on our server.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Files
  alias Bonfire.Files.Media

  setup do
    # a copy, as the importer's own staged dir would hold it, so the upload can't touch the fixture
    path =
      Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-staged.jpg")

    File.cp!(Bonfire.Files.Simulation.image_with_exif_file().path, path)
    on_exit(fn -> File.rm(path) end)

    {:ok, me: fake_user!(), path: path}
  end

  test "a staged file and its attachment become local media with the alt text", %{
    me: me,
    path: path
  } do
    attachment = %{
      "type" => "Document",
      "mediaType" => "image/jpeg",
      "url" => "media_attachments/files/000/000/001/original/pic.jpg",
      "name" => "a small photo"
    }

    assert {:ok, %Media{} = media} = Files.ap_receive_local_attachment(me, path, attachment)

    refute String.starts_with?(media.path, "http")
    assert media.size > 0
    assert media.media_type =~ "image/"
    assert media.metadata["alt"] == "a small photo"
  end
end
