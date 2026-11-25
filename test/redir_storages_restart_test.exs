# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.RedirStoragesRestartTest do
  @moduledoc """
  A configured `/files/redir` storage key (see `Bonfire.Files.redir_url/2`) is an instance setting, eg. an imported site's `:lookup`. After a restart it comes back from the database into Config as it was put, so the bodies' `/files/redir/<key>/…` URLs keep resolving.
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Common.Config
  alias Bonfire.Common.Settings
  alias Bonfire.Files

  @storages %{"blog" => :lookup, "old" => {:alias, "local"}}

  setup do
    previous = Application.get_env(:bonfire_files, :redir_storages)

    on_exit(fn ->
      Application.put_env(:bonfire_files, :redir_storages, previous)
    end)

    {:ok, me: fake_user!()}
  end

  # what boot does: the instance settings read back from the database into Config
  defp restart do
    Application.delete_env(:bonfire_files, :redir_storages)
    Bonfire.Common.Settings.LoadInstanceConfig.load_config()
  end

  # Config gives them back as a keyword list with atom keys after a restart, so they're read through `redir_storages/0`
  test "after a restart the storage keys still resolve", %{me: me} do
    Settings.put([:bonfire_files, :redir_storages], @storages,
      scope: :instance,
      skip_boundary_check: true
    )

    restart()

    assert Files.redir_storages() == @storages
    assert Config.get([:bonfire_files, :redir_storages], %{}) |> Enum.count() == 2

    url = "https://blog.example.com/wp-content/uploads/2018/12/a.jpg"
    {:ok, remote} = Files.save_url_as_media(me, url, %{media_type: "image/jpeg"})

    assert Files.redir_url("data/uploads/#{me.id}/images/#{remote.id}.jpg", "blog") == url
  end
end
