# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.RemoteMediaUrlOnlyTest do
  @moduledoc """
  Media named by an incoming federated object must only ever be a remote URL. `Bonfire.Files.upload/5` reads any string that is not `http(s)` as a path on this server, so an attachment or image whose `url` is such a path would copy a file from our own disk into public storage.

  `@local` is an image that really exists, so a refusal can't be put down to a missing file. Each test is paired with the same input as a remote URL, which proves the media is made when it is allowed.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Files
  alias Bonfire.Files.Media

  @local Bonfire.Files.Simulation.icon_file().path
  @remote "https://a.local/i.png"

  setup do
    {:ok, me: fake_user!()}
  end

  defp attachment(url),
    do: %{"type" => "Document", "mediaType" => "image/png", "url" => url}

  defp image(url),
    do: %{"type" => "Image", "mediaType" => "image/png", "url" => url}

  # every form of "a file on this server" a sender could write
  defp local_forms,
    do: [@local, "file://" <> @local, Path.relative_to_cwd(@local), "../../../.." <> @local]

  test "an attachment with a remote url becomes media", %{me: me} do
    assert [%Media{path: @remote}] =
             Files.ap_receive_attachments(me, false, [attachment(@remote)])
  end

  test "an attachment whose url is a path on this server is refused", %{me: me} do
    for url <- local_forms() do
      assert [] == Files.ap_receive_attachments(me, false, [attachment(url)]) |> List.wrap(),
             "should refuse #{url}"
    end
  end

  test "a primary image with a remote url becomes media", %{me: me} do
    assert [%Media{path: @remote}] = Files.ap_receive_attachments(me, image(@remote), [])
  end

  test "a primary image whose url is a path on this server is refused", %{me: me} do
    for url <- local_forms() do
      assert [] == Files.ap_receive_attachments(me, image(url), []) |> List.wrap(),
             "should refuse #{url}"
    end
  end

  test "save_url_as_media refuses anything but an http(s) url", %{me: me} do
    assert {:ok, %Media{path: @remote}} = Files.save_url_as_media(me, @remote)

    for url <- local_forms() do
      assert {:error, :not_a_remote_url} == Files.save_url_as_media(me, url),
             "should refuse #{url}"
    end
  end
end
