# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.UploadRedirectTest do
  @moduledoc """
  `/files/redir/<storage>/<path>` redirects to wherever a file is now. Besides `local` and `s3`, the storage can be a key from config: a lookup (the `Media` id in the path finds a `Media` whose file is still elsewhere, eg. an imported site's, and it redirects there) or an alias of another storage (the same URL, once the files are stored here).
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]
  @endpoint Application.compile_env!(:bonfire, :endpoint_module)

  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader

  setup do
    me = fake_user!()

    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-a.png")
    File.cp!(Path.expand("fixtures/150.png", __DIR__), path)
    on_exit(fn -> File.rm(path) end)

    {:ok, media} = Files.upload(ImageUploader, me, %{path: path, filename: "a.png"})
    local = Files.local_path(ImageUploader, media)
    on_exit(fn -> local && File.rm(local) end)

    # eg. `/files/redir/local/data/uploads/<creator>/images/<id>.png`
    redir_path = URI.parse(Files.inline_url(media)).path

    {:ok, me: me, media: media, redir_path: redir_path}
  end

  defp location(conn), do: List.first(get_resp_header(conn, "location"))

  test "an upload's own URL redirects to its file (as before)", %{redir_path: redir_path} do
    assert "/files/redir/local/" <> _ = redir_path

    conn = get(build_conn(), redir_path)

    assert conn.status == 302
    assert location(conn) =~ "/data/uploads/"
  end

  test "an alias key redirects as the storage it stands for does", %{redir_path: redir_path} do
    Process.put([:bonfire_files, :redir_storages], %{"blog" => {:alias, "local"}})

    aliased = String.replace_prefix(redir_path, "/files/redir/local/", "/files/redir/blog/")

    # the aliased URL first: resolved URLs are cached by path, so asking for the `local` one first would answer this from the cache
    conn = get(build_conn(), aliased)

    assert conn.status == 302
    assert location(conn) == location(get(build_conn(), redir_path))
  end

  # an older URL may name a storage we no longer know: it's read from the instance's own storage, not always from S3
  test "an unknown storage key redirects as the instance's storage does", %{
    redir_path: redir_path
  } do
    Process.put([:bonfire_files, :storage], :local)

    unknown = String.replace_prefix(redir_path, "/files/redir/local/", "/files/redir/gone/")

    # the unknown one first: resolved URLs are cached by path
    conn = get(build_conn(), unknown)

    assert conn.status == 302
    assert location(conn) == location(get(build_conn(), redir_path))
  end

  test "a lookup key finds the Media by the id in the usual path and redirects to its file elsewhere",
       %{me: me} do
    Process.put([:bonfire_files, :redir_storages], %{"blog" => :lookup})

    url = "https://blog.example.com/wp-content/uploads/2018/12/a.jpg"
    {:ok, remote} = Files.save_url_as_media(me, url, %{media_type: "image/jpeg"})

    conn = get(build_conn(), "/files/redir/blog/data/uploads/#{me.id}/images/#{remote.id}.jpg")

    assert conn.status == 302
    assert location(conn) == url

    # the usual path without its `data/uploads/` start too
    conn = get(build_conn(), "/files/redir/blog/#{me.id}/images/#{remote.id}.jpg")
    assert location(conn) == url
  end

  test "a lookup key with no such Media is not found", %{me: me} do
    Process.put([:bonfire_files, :redir_storages], %{"blog" => :lookup})

    missing = Needle.UID.generate(Bonfire.Files.Media)
    conn = get(build_conn(), "/files/redir/blog/#{me.id}/images/#{missing}.jpg")

    assert conn.status == 404
  end

  test "a path that climbs out of its storage is not found" do
    Process.put([:bonfire_files, :redir_storages], %{"blog" => {:alias, "local"}})

    for storage <- ["local", "blog"] do
      conn =
        get(build_conn(), "/files/redir/#{storage}/data/uploads/../../config/prod.secret.exs")

      assert conn.status == 404
    end
  end
end
