# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.MediaAdminTest do
  @moduledoc """
  An instance admin may update or delete any media, also when loaded the way a LiveView or GraphQL request loads `current_user` (`Users.get_current/2`, which does not preload the account's `instance_admin`).
  """
  use Bonfire.DataCase, async: false
  @moduletag :backend

  import Bonfire.UI.Common.Testing.Helpers, only: [fake_admin!: 1]

  alias Bonfire.Files.Media

  setup do
    owner = fake_user!()
    account = fake_account!()
    admin = fake_admin!(account)
    loaded_admin = Bonfire.Me.Users.get_current(id(admin), id(account))

    {:ok, owner: owner, admin: admin, loaded_admin: loaded_admin, other: fake_user!()}
  end

  defp media_of(owner, n) do
    Media.maybe_save(
      owner,
      "https://example.com/admin-test/#{n}-#{System.unique_integer([:positive])}",
      %{}
    )
  end

  test "an admin as returned by the fake helper can update another user's media (control)", ctx do
    media = media_of(ctx.owner, 1)

    assert {:ok, _} = Media.update(ctx.admin, media, %{metadata: %{"label" => "by admin"}})
  end

  test "a non-admin can't update another user's media (control)", ctx do
    media = media_of(ctx.owner, 2)

    assert {:error, :unauthorized} =
             Media.update(ctx.other, media, %{metadata: %{"label" => "nope"}})
  end

  test "an admin loaded like a LiveView/GraphQL current_user can update another user's media",
       ctx do
    media = media_of(ctx.owner, 3)

    assert {:ok, updated} =
             Media.update(ctx.loaded_admin, media, %{metadata: %{"label" => "by admin"}})

    assert updated.metadata["label"] == "by admin"
  end

  test "an admin loaded like a LiveView/GraphQL current_user can delete another user's media",
       ctx do
    media = media_of(ctx.owner, 4)

    assert {:ok, _} = Media.hard_delete(nil, media, current_user: ctx.loaded_admin)
    assert {:error, :not_found} = Media.one(id: media.id)
  end
end
