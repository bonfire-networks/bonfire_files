# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Media do
  use Pointers.Pointable,
    otp_app: :bonfire_files,
    table_id: "30NF1REF11ESC0NTENT1SGREAT",
    source: "bonfire_files_media"

  import Bonfire.Common.Config, only: [repo: 0]

  alias Ecto.Changeset
  alias Bonfire.Common.Types
  alias Bonfire.Files.Media
  alias Bonfire.Files.Media.Queries

  @type t :: %__MODULE__{}

  pointable_schema do
    # has_one(:preview, __MODULE__)
    belongs_to(:user, Pointers.Pointer)
    field(:path, :string)
    field(:size, :integer)
    field(:media_type, :string)
    field(:metadata, :map)
    field(:file, :map, virtual: true)
    field(:deleted_at, :utc_datetime_usec)
  end

  @create_required ~w(path size media_type)a
  @create_cast @create_required ++ ~w(id metadata)a

  def changeset(user, attrs) do
    %__MODULE__{}
    |> Changeset.cast(attrs, @create_cast)
    |> Changeset.validate_required(@create_required)
    |> Changeset.validate_length(:media_type, max: 255)
    |> Changeset.change(user_id: Types.ulid(user) || "0AND0MSTRANGERS0FF1NTERNET")
  end

  def insert(user, %{path: path} = file, file_info, attrs) do
    with {:ok, media} <- insert(user, path, file_info, attrs) do
      {:ok, Map.put(media, :file, file)}
    end

    # |> debug
  end

  def insert(user, url_or_path, file_info, attrs) do
    metadata =
      Map.merge(
        Map.get(attrs, :metadata) || %{},
        Map.drop(file_info, [:size, :media_type])
      )

    attrs =
      attrs
      |> Map.put(:path, url_or_path)
      |> Map.put(:size, file_info[:size])
      |> Map.put(:media_type, file_info[:media_type])
      |> Map.put(:metadata, metadata)

    with {:ok, media} <- repo().insert(Media.changeset(user, attrs)) do
      {:ok, Map.put(media, :user, user)}
    end

    # |> debug
  end

  def one(filters), do: repo().single(Queries.query(Media, filters))

  def many(filters \\ []), do: {:ok, repo().many(Queries.query(Media, filters))}

  def update_by(filters, updates) do
    repo().update_all(Queries.query(Media, filters), set: updates)
  end

  @doc """
  Delete an upload, removing it from indexing, but the files remain available.
  """
  @spec soft_delete(Media.t()) :: {:ok, Media.t()} | {:error, Changeset.t()}
  def soft_delete(%Media{} = media) do
    Bonfire.Common.Repo.Delete.soft_delete(media)
  end

  @doc """
  Delete an upload, removing any associated files.
  """
  @spec hard_delete(atom, Media.t()) :: :ok | {:error, Changeset.t()}
  def hard_delete(module, %Media{} = media) do
    repo().transaction(fn ->
      with {:ok, media} <- repo().delete(media),
           {:ok, deleted} <- module.delete({media.path, media.user_id}) do
        {:ok, deleted}
      end
    end)
  end

  @doc false
  def hard_delete_soft_deleted_files() do
    delete_by(deleted: true)
  end

  # FIXME: doesn't cleanup files
  defp delete_by(filters) do
    Queries.query(Media)
    |> Queries.filter(filters)
    |> repo().delete_all()
  end
end

defmodule Bonfire.Files.Media.Migrations do
  @moduledoc false
  use Ecto.Migration
  import Pointers.Migration
  alias Bonfire.Files.Media

  defp make_media_table(exprs) do
    quote do
      require Pointers.Migration

      Pointers.Migration.create_pointable_table Media do
        Ecto.Migration.add(:user_id, Pointers.Migration.strong_pointer(), null: false)

        Ecto.Migration.add(:path, :text, null: false)
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
end
