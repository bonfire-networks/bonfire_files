defmodule Bonfire.Files.Repo.Migrations.AddFilesIndexes do
  @moduledoc false
use Ecto.Migration 
  use Needle.Migration.Indexable

  def up do
    Bonfire.Files.Media.Migrations.add_media_creator_index()
  end

  def down, do: nil
end
