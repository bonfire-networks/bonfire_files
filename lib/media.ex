# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Media do
  use Needle.Pointable,
    otp_app: :bonfire_files,
    table_id: "30NF1REF11ESC0NTENT1SGREAT",
    source: "bonfire_files_media"

  import Bonfire.Common.Config, only: [repo: 0]
  import Untangle

  alias Ecto.Changeset
  alias Bonfire.Common.Enums
  alias Bonfire.Common.Types
  alias Bonfire.Files.Media
  alias Bonfire.Files.Media.Queries

  @type t :: %__MODULE__{}

  pointable_schema do
    # has_one(:preview, __MODULE__)
    belongs_to(:user, Needle.Pointer)

    # old path info from Waffle
    field(:path, :string)

    # new File data from Entrepot
    field :file, Entrepot.Ecto.Type
    # field(:file, :map, virtual: true)

    field(:size, :integer)
    field(:media_type, :string)
    field(:metadata, :map)

    field(:deleted_at, :utc_datetime_usec)
  end

  @create_required ~w(path size media_type user_id)a
  @cast @create_required ++ ~w(id metadata)a

  defp changeset(media \\ %__MODULE__{}, user, attrs)

  defp changeset(media, user, %{url: url} = attrs) when is_binary(url) do
    common_changeset(media, user, attrs)
  end

  defp changeset(media, user, attrs) do
    common_changeset(media, user, attrs)
    |> upload_changeset(attrs)
  end

  defp common_changeset(media, _user, attrs) do
    base_changeset(media, attrs)
    |> Changeset.validate_required(@create_required)
    |> Changeset.validate_length(:media_type, max: 255)
    |> debug()
  end

  defp base_changeset(media, attrs) do
    media
    |> Changeset.cast(attrs, @cast)
  end

  defp upload_changeset(changeset, attrs) do
    changeset
    |> Bonfire.Files.CapsuleIntegration.Attacher.upload(:file, attrs)
  end

  def insert(user, %{path: path} = file, file_info, attrs) do
    with {:ok, media} <- insert(user, path, file_info, attrs) do
      {:ok, Map.put_new(media, :file, file)}
    end
  end

  def insert(user, url_or_path, file_info, attrs) do
    metadata =
      Map.merge(
        Map.get(attrs, :metadata) || %{},
        Map.drop(file_info, [:size, :media_type])
      )
      |> Enums.filter_empty(%{})

    attrs =
      attrs
      |> Map.put_new(:file, url_or_path)
      |> Map.put(:path, url_or_path)
      |> Map.put(:size, file_info[:size])
      |> Map.put(:media_type, file_info[:media_type])
      |> Map.put(:module, file_info[:module])
      |> Map.put(:user_id, Types.ulid(user) || "0AND0MSTRANGERS0FF1NTERNET")
      |> Map.put(:metadata, metadata)

    with {:ok, media} <- repo().insert(changeset(user, attrs)) do
      {:ok, Map.put(media, :user, user)}
    end

    # |> debug
  end

  def one(filters, _opts \\ []), do: repo().single(Queries.query(Media, filters))

  def many(filters \\ [], _opts \\ []), do: {:ok, repo().many(Queries.query(Media, filters))}

  def get_by_path(url) when is_binary(url) do
    one(path: url)
  end

  def get_by_path(_) do
    {:error, :not_found}
  end

  def update(_user \\ nil, %{} = media, updates) do
    base_changeset(media, updates)
    |> repo().update()
  end

  def update_by(filters, updates) do
    Queries.query(Media, filters)
    |> Ecto.Query.exclude(:order_by)
    |> repo().update_all(set: updates)
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
  import Needle.Migration
  alias Bonfire.Files.Media

  defp make_media_table(exprs) do
    quote do
      require Needle.Migration

      Needle.Migration.create_pointable_table Media do
        Ecto.Migration.add(:user_id, Needle.Migration.strong_pointer(), null: false)

        Ecto.Migration.add(:path, :text, null: false)
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
end
