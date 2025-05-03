defmodule Bonfire.Repo.Migrations.MediaPathNull do
  @moduledoc false
  use Ecto.Migration


  def up do
    Bonfire.Files.Media.Migrations.change_path_to_nullable()
  end
  def down do
    nil
  end


end
