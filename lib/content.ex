# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Content do
  use Pointers.Pointable,
    otp_app: :bonfire_files,
    table_id: "B0NF1REF11ESC0NTENT1SGREAT",
    source: "bonfire_content"

  import Bonfire.Repo.Changeset, only: [change_public: 1]

  alias Ecto.Changeset
  alias Bonfire.Data.Identity.User

  @type t :: %__MODULE__{}

  pointable_schema do
    # has_one(:preview, __MODULE__)
    belongs_to(:uploader, User)
    field(:path, :string)
    field(:size, :integer)
    field(:media_type, :string)
    field(:metadata, :map) # currently unused
    field(:is_public, :boolean, virtual: true)
    field(:published_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
    timestamps(inserted_at: :created_at)
  end

  @create_cast ~w(metadata is_public)a
  @create_required ~w(path size media_type)a

  def changeset(%User{} = uploader, attrs) do
    %__MODULE__{}
    |> Changeset.cast(attrs, @create_cast)
    |> Changeset.validate_required(@create_required)
    |> Changeset.validate_length(:media_type, max: 255)
    |> Changeset.change(
      is_public: true,
      uploader_id: Bonfire.Common.Utils.maybe_get(uploader, :id)
    )
    |> change_public()
  end
end

defmodule Bonfire.Files.Content.Migration do
  use Ecto.Migration
  import Pointers.Migration
  alias Bonfire.Files.Content

  defp make_content_table(exprs) do
    quote do
      require Pointers.Migration
      Pointers.Migration.create_pointable_table(Content) do
        Ecto.Migration.add(:uploader_id,
          Pointers.Migration.strong_pointer(Bonfire.Data.Identity.User))
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

  defmacro create_content_table(), do: make_content_table([])
  defmacro create_content_table([do: {_, _, body}]), do: make_content_table(body)

  def drop_content_table(), do: drop_pointable_table(Content)

  # add constraint to forbid neither references set
  defp make_content_path_index(opts \\ []) do
    quote do
      Ecto.Migration.create_if_not_exists(
        Ecto.Migration.index("bonfire_content", [:path], unquote(opts))
      )
    end
  end

  def drop_content_path_index(opts \\ []) do
    drop_if_exists(Ecto.Migration.constraint(
          "bonfire_content", [:path], opts))
  end

  defp mc(:up) do
    quote do
      unquote(make_content_table([]))
      unquote(make_content_path_index())
    end
  end

  defp mc(:down) do
    quote do
      __MODULE__.drop_content_table()
      __MODULE__.drop_content_path_index()
    end
  end

  defmacro migrate_content() do
    quote do
      if Ecto.Migration.direction() == :up,
        do: unquote(mc(:up)),
        else: unquote(mc(:down))
    end
  end

  defmacro migrate_content(dir), do: mc(dir)
end
