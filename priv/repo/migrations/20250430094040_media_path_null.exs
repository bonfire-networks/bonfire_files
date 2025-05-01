defmodule Bonfire.Repo.Migrations.MediaPathNull do
  @moduledoc false
  use Ecto.Migration


  def change do
    Bonfire.Files.Media.Migrations.change_path_to_nullable()
  end


end
