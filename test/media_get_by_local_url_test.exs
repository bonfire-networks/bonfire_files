# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.MediaGetByLocalUrlTest do
  @moduledoc """
  `Media.get_by_url/1` finds a local upload from the URL it's served at (`/files/redir/<storage>/<path>`, see `Bonfire.Files.inline_url/1`), as it finds a remote one from its own URL: so a body that names an upload by its URL (eg. an image dragged in from a post) leads back to it, rather than to a fetch of our own page.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  import Bonfire.Files.Simulation

  alias Bonfire.Files
  alias Bonfire.Files.Media
  alias Bonfire.Files.ImageUploader

  setup do
    me = fake_user!()
    {:ok, media} = Files.upload(ImageUploader, me, image_file())
    {:ok, media: media}
  end

  test "a local upload is found from its absolute URL on this instance", %{media: media} do
    url = Files.inline_url(media)
    assert url =~ "/files/redir/"
    assert String.starts_with?(url, Bonfire.Common.URIs.base_url())

    assert {:ok, %{id: id}} = Media.get_by_url(url)
    assert id == media.id
  end

  test "a local upload is found from its URL relative to this instance", %{media: media} do
    %URI{path: path} = URI.parse(Files.inline_url(media))

    assert {:ok, %{id: id}} = Media.get_by_url(path)
    assert id == media.id
  end

  test "control: the same path on another instance isn't this upload", %{media: media} do
    %URI{path: path} = URI.parse(Files.inline_url(media))

    assert {:error, :not_found} = Media.get_by_url("https://elsewhere.example.com" <> path)
  end
end
