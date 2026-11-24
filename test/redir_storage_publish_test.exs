# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.RedirStoragePublishTest do
  @moduledoc """
  A `Media` whose file is in a configured `/files/redir` storage (eg. an imported site's file, still on that site, see `Bonfire.Files.redir_url/2`) records that storage in its own `file` locator, as any upload records its storage. Its URL is then built the usual way: placed in a body and federated in `attachment` by the same `/files/redir/<storage>/…` URL, so a receiver matching `content` against `attachment` sees one image, and it keeps working once the file is stored here. Any other remote `Media` keeps its own URL.
  """
  use Bonfire.DataCase, async: false

  alias Bonfire.Files
  alias Bonfire.Files.Media

  @remote "https://blog.example.local/wp-content/uploads/2018/12/a.jpg"

  setup do
    Process.put([:bonfire_files, :redir_storages], %{"blog" => :lookup})
    :ok
  end

  defp media(media_type, storage \\ "blog") do
    id = Needle.UID.generate(Media)
    creator_id = Needle.UID.generate()

    %Media{
      id: id,
      creator_id: creator_id,
      path: @remote,
      media_type: media_type,
      metadata: %{},
      file:
        if(storage,
          do: %Entrepot.Locator{
            storage: storage,
            id: "data/uploads/#{creator_id}/images/#{id}.jpg"
          }
        )
    }
  end

  test "its URL is the `/files/redir` URL of its storage and path" do
    media = media("image/jpeg")

    assert Files.permanent_url(nil, media) ==
             Bonfire.Common.URIs.base_url() <> "/files/redir/blog/#{media.file.id}"

    assert Files.inline_url(media) == Files.permanent_url(nil, media)
  end

  test "an image in a configured storage federates with the URL its body places it by" do
    media = media("image/jpeg")

    assert %{"type" => "Image", "url" => url} = Files.ap_publish_activity(media)
    assert url == Files.inline_url(media)
    assert url =~ "/files/redir/blog/"
  end

  test "so does audio or video" do
    for type <- ["audio/mpeg", "video/mp4"] do
      media = media(type)

      assert %{"url" => url} = Files.ap_publish_activity(media)
      assert url == Files.inline_url(media)
    end
  end

  # its file is still on the other site: there's nothing of ours to remove
  test "deleting its files touches no storage" do
    media = media("image/jpeg")

    assert Files.local_path(nil, media) == nil
    refute match?({:error, _}, Files.delete_files(nil, media, skip_boundary_check: true))
  end

  # the control: without a configured storage, a remote file federates with its own URL, as before
  test "any other remote image federates with its own URL" do
    assert %{"type" => "Image", "url" => @remote} =
             Files.ap_publish_activity(media("image/jpeg", nil))
  end
end
