defmodule Bonfire.Files.Migrations do
  @moduledoc false
  import Ecto.Migration
  import Needle.Migration
  alias Bonfire.Files

  @files_table Files.__schema__(:source)

  # create_files_table/{0,1}

  defp make_files_table(exprs) do
    quote do
      import Needle.Migration

      Needle.Migration.create_mixin_table Bonfire.Files do
        add_pointer(:media_id, :strong, Needle.Pointer, primary_key: true)

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

defmodule Bonfire.Files.Media.Migrations do
  @moduledoc false
  use Ecto.Migration
  import Needle.Migration
  alias Bonfire.Files.Media

  defp make_media_table(exprs) do
    quote do
      require Needle.Migration

      Needle.Migration.create_pointable_table Media do
        add_pointer(:user_id, :strong, Needle.Pointer, null: false)
        #  FYI user_id is renamed to creator_id in a migration
        # add_pointer(:creator_id, :strong, Needle.Pointer, null: false)

        Ecto.Migration.add(:path, :text, null: true)
        Ecto.Migration.add(:file, :jsonb)
        Ecto.Migration.add(:size, :integer, null: false)
        # see https://stackoverflow.com/a/643772 for size
        Ecto.Migration.add(:media_type, :string, null: false, size: 255)
        Ecto.Migration.add(:metadata, :jsonb)
        Ecto.Migration.add(:deleted_at, :utc_datetime_usec)

        unquote_splicing(exprs)
      end
    end
  end

  defmacro create_media_table(), do: make_media_table([])
  defmacro create_media_table(do: {_, _, body}), do: make_media_table(body)

  def drop_media_table(), do: drop_pointable_table(Media)

  defp make_media_path_index(opts \\ []) do
    quote do
      Ecto.Migration.create_if_not_exists(
        Ecto.Migration.index("bonfire_files_media", [:path], unquote(opts))
      )
    end
  end

  def drop_media_path_index(opts \\ []) do
    drop_if_exists(Ecto.Migration.constraint("bonfire_files_media", :path, opts))
  end

  defp mc(:up) do
    quote do
      unquote(make_media_table([]))
      unquote(make_media_path_index())
    end
  end

  defp mc(:down) do
    quote do
      Bonfire.Files.Media.Migrations.drop_media_path_index()
      Bonfire.Files.Media.Migrations.drop_media_table()
    end
  end

  defmacro migrate_media() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(mc(:up)),
        else: unquote(mc(:down))
    end
  end

  defmacro migrate_media(dir), do: mc(dir)

  @doc """
  Alters the path column in bonfire_files_media table to allow NULL values.
  """
  def change_path_to_nullable() do
    alter table("bonfire_files_media") do
      modify :path, :text, null: true
    end
  end
end
