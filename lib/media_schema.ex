# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Media do
  use Pointers.Pointable,
    otp_app: :bonfire_files,
    table_id: "30NF1REF11ESC0NTENT1SGREAT",
    source: "bonfire_files_media"

  import Bonfire.Repo.Common, only: [change_public: 1]

  alias Ecto.Changeset

  @type t :: %__MODULE__{}

  pointable_schema do
    # has_one(:preview, __MODULE__)
    belongs_to(:user, Pointers.Pointer)
    field(:path, :string)
    field(:size, :integer)
    field(:media_type, :string)
    field(:metadata, :map) # currently unused
    field(:is_public, :boolean, virtual: true)
    field(:published_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
    timestamps(inserted_at: :created_at)
  end

  @create_required ~w(path size media_type)a
  @create_cast @create_required ++ ~w(metadata is_public)a

  def changeset(%{id: user_id}, attrs) do
    %__MODULE__{}
    |> Changeset.cast(attrs, @create_cast)
    |> Changeset.validate_required(@create_required)
    |> Changeset.validate_length(:media_type, max: 255)
    |> Changeset.change(
      is_public: true,
      user_id: user_id
    )
    |> change_public()
  end
end

defmodule Bonfire.Files.Media.Migration do
  use Ecto.Migration
  import Pointers.Migration
  alias Bonfire.Files.Media

  defp make_media_table(exprs) do
    quote do
      require Pointers.Migration
      Pointers.Migration.create_pointable_table(Media) do
        Ecto.Migration.add(:user_id, Pointers.Migration.strong_pointer(), null: false)
        Ecto.Migration.add(:path, :text, null: false)
        Ecto.Migration.add(:size, :integer, null: false)
        # see https://stackoverflow.com/a/643772 for size
        Ecto.Migration.add(:media_type, :string, null: false, size: 255)
        Ecto.Migration.add(:metadata, :jsonb)
        Ecto.Migration.add(:published_at, :utc_datetime_usec)
        Ecto.Migration.add(:deleted_at, :utc_datetime_usec)
        Ecto.Migration.timestamps(inserted_at: :created_at, type: :utc_datetime_usec)

        unquote_splicing(exprs)
      end
    end
  end

  defmacro create_media_table(), do: make_media_table([])
  defmacro create_media_table([do: {_, _, body}]), do: make_media_table(body)

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
      Bonfire.Files.Media.Migration.drop_media_path_index()
      Bonfire.Files.Media.Migration.drop_media_table()
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
end
