defmodule Bonfire.Files.Repo.Migrations.FilesCreatorID do
  @moduledoc false
  use Ecto.Migration

  import Needle.Migration

  def up do
    Ecto.Migration.rename table("bonfire_files_media"), :user_id, to: :creator_id
  end

  def down, do: nil
end
