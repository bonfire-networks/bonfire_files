# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.StoreAtTest do
  @moduledoc """
  `Bonfire.Files.store_at/3` stores a file for a `Media` that so far points at a file elsewhere (eg. an image imported from a site, see `Bonfire.Files.put_storage_locator/2`): resized as an upload of its type is, in this instance's storage, at the path its locator already names. The `Media` keeps its id and locator, so its attachments, the bodies that place it and what was federated with it all stay.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]
  @endpoint Application.compile_env!(:bonfire, :endpoint_module)

  alias Bonfire.Common.Repo
  alias Bonfire.Files
  alias Bonfire.Files.Media

  @remote "https://blog.example.local/wp-content/uploads/2018/12/big.png"
  @remote_size "https://blog.example.local/wp-content/uploads/2018/12/big-300x400.png"

  setup do
    Process.put([:bonfire_files, :storage], :local)
    Process.put([:bonfire_files, :redir_storages], %{"blog" => :lookup})

    me = fake_user!()

    {:ok, media} = Files.save_url_as_media(me, @remote, %{media_type: "image/png"})

    {:ok, media} =
      Media.update(nil, media, %{metadata: %{"urls" => [@remote, @remote_size]}},
        skip_boundary_check: true
      )

    {:ok, media} = Files.put_storage_locator(media, "blog")

    # the copied file, as an admin's copy of the site's uploads folder holds it
    source = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-big.png")
    File.cp!(Path.expand("fixtures/600x800.png", __DIR__), source)
    on_exit(fn -> File.rm(source) end)

    stored_at = Entrepot.Storages.Disk.path(media.file.id)
    on_exit(fn -> File.rm(stored_at) end)

    {:ok, me: me, media: media, source: source, stored_at: stored_at}
  end

  defp location(conn), do: List.first(get_resp_header(conn, "location"))

  test "stores the file, resized, at the path the Media's locator names, keeping its id and locator, with its path no longer the other site's",
       %{media: media, source: source, stored_at: stored_at} do
    refute File.exists?(stored_at)

    assert {:ok, stored} = Files.store_at(media, source)

    assert stored.id == media.id
    assert stored.file.id == media.file.id
    assert stored.file.storage == "blog"
    assert File.exists?(stored_at)

    refute stored.path =~ "blog.example.local"
    assert stored.path == stored.file.id

    # dimensions need the image tools (vips or ImageMagick), which the CI runner doesn't have
    if !System.get_env("CI") do
      assert {width, height} = Bonfire.Files.MediaEdit.dimensions(stored_at)
      assert width <= 580 and height <= 700
      assert stored.metadata["width"] == width
    end

    # still found by any of its sizes' URLs on the site, as imports and old-URL redirects find it
    assert [%{id: id}] = Media.many_by_urls([@remote_size])
    assert id == media.id
  end

  test "every URL it's given by is our own, and its `/files/redir` URL leads to the stored file",
       %{media: media, source: source} do
    assert {:ok, stored} = Files.store_at(media, source)
    stored = Repo.reload!(stored)

    for url <- [
          Bonfire.Common.Media.media_url(stored),
          Files.inline_url(stored),
          Files.ap_publish_activity(stored)["url"]
        ] do
      assert is_binary(url)
      refute url =~ "blog.example.local"
    end

    redir = URI.parse(Files.inline_url(stored)).path
    assert "/files/redir/blog/" <> _ = redir

    conn = get(build_conn(), redir)
    assert conn.status == 302
    assert location(conn) =~ stored.file.id
    refute location(conn) =~ "/files/redir/"
  end

  # the instance's upload size limit is for what people upload: a file the site already published is stored whatever its size, as only its resized copy is kept
  test "a file over the instance's upload size limit is still stored, while an upload of it is refused",
       %{me: me, media: media, source: source, stored_at: stored_at} do
    Process.put([:bonfire_files, :max_user_images_file_size], 0.0001)
    on_exit(fn -> Process.delete([:bonfire_files, :max_user_images_file_size]) end)

    upload_copy = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-big.png")
    File.cp!(source, upload_copy)
    on_exit(fn -> File.rm(upload_copy) end)

    assert {:error, %Bonfire.Fail{code: :file_too_large}} =
             Files.upload(Bonfire.Files.ImageUploader, me, upload_copy)

    assert {:ok, stored} = Files.store_at(media, source)
    assert stored.path == stored.file.id
    assert File.exists?(stored_at)
  end

  test "storing it again leaves the stored file as it is", %{
    media: media,
    source: source,
    stored_at: stored_at
  } do
    assert {:ok, stored} = Files.store_at(media, source)
    %{mtime: mtime, size: size} = File.stat!(stored_at, time: :posix)

    assert {:ok, again} = Files.store_at(Repo.reload!(stored), source)

    assert again.id == media.id
    assert %{mtime: ^mtime, size: ^size} = File.stat!(stored_at, time: :posix)
  end
end
