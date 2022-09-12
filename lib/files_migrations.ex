defmodule Bonfire.Files.Migrations do
  import Ecto.Migration
  import Pointers.Migration
  alias Bonfire.Files

  @files_table Files.__schema__(:source)

  # create_files_table/{0,1}

  defp make_files_table(exprs) do
    quote do
      require Pointers.Migration

      Pointers.Migration.create_mixin_table Bonfire.Files do
        Ecto.Migration.add(:media_id, Pointers.Migration.strong_pointer(), primary_key: true)

        unquote_splicing(exprs)
      end
    end
  end

  defmacro create_files_table(), do: make_files_table([])
  defmacro create_files_table(do: {_, _, body}), do: make_files_table(body)

  def drop_files_table(), do: drop_mixin_table(Files)

  def migrate_files_media_index(dir \\ direction(), opts \\ [])

  def migrate_files_media_index(:up, opts),
    do: create_if_not_exists(index(@files_table, [:media_id], opts))

  def migrate_files_media_index(:down, opts),
    do: drop_if_exists(index(@files_table, [:media_id], opts))

  defp mf(:up) do
    quote do
      Bonfire.Files.Migrations.create_files_table()
      Bonfire.Files.Migrations.migrate_files_media_index()
    end
  end

  defp mf(:down) do
    quote do
      Bonfire.Files.Migrations.migrate_files_media_index()
      Bonfire.Files.Migrations.drop_files_table()
    end
  end

  defmacro migrate_files() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(mf(:up)),
        else: unquote(mf(:down))
    end
  end

  defmacro migrate_files(dir), do: mf(dir)
end
