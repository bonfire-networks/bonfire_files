# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Content do
  use Pointers.Pointable,
    otp_app: :bonfire_files,
    table_id: "B0NF1REF11ESC0NTENT1SGREAT",
    source: "bonfire_content"

  import Bonfire.Repo.Changeset, only: [change_public: 1]

  alias Ecto.Changeset
  alias Bonfire.Data.Identity.User
  alias Bonfire.Files.{ContentMirror, ContentUpload}

  @type t :: %__MODULE__{}

  pointable_schema do
    # has_one(:preview, __MODULE__)
    belongs_to(:uploader, User)
    belongs_to(:content_mirror, ContentMirror)
    belongs_to(:content_upload, ContentUpload)
    field(:url, :string, virtual: true)
    field(:media_type, :string)
    field(:metadata, :map)
    field(:is_public, :boolean, virtual: true)
    field(:published_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
    timestamps(inserted_at: :created_at)
  end

  @create_cast ~w(media_type metadata is_public)a
  @create_required ~w(media_type)a

  def mirror_changeset(%ContentMirror{} = mirror, uploader, attrs) do
    common_changeset(uploader, attrs)
    |> Changeset.change(content_mirror_id: mirror.id)
  end

  def upload_changeset(%ContentUpload{} = upload, uploader, attrs) do
    common_changeset(uploader, attrs)
    |> Changeset.change(content_upload_id: upload.id)
  end

  defp common_changeset(uploader, attrs) do
    %__MODULE__{}
    |> Changeset.cast(attrs, @create_cast)
    |> Changeset.validate_required(@create_required)
    |> Changeset.validate_length(:media_type, max: 256)
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
  alias Bonfire.Files.{Content, ContentUpload, ContentMirror}

  defp make_content_table(exprs) do
    quote do
      require Pointers.Migration
      Pointers.Migration.create_pointable_table(Content) do
        # see https://stackoverflow.com/a/643772 for size
        Ecto.Migration.add(:uploader_id,
          Pointers.Migration.strong_pointer(Bonfire.Data.Identity.User))
        Ecto.Migration.add(:content_upload_id,
          Pointers.Migration.strong_pointer(ContentUpload))
        Ecto.Migration.add(:content_mirror_id,
          Pointers.Migration.strong_pointer(ContentMirror))
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
  defp make_content_neither_reference_constraint(_opts \\ []) do
    quote do
      Ecto.Migration.create_if_not_exists(
        Ecto.Migration.constraint(
          "bonfire_content",
          :mirror_or_upload_must_be_set,
          check: "content_mirror_id is not null or content_upload_id is not null"
        )
      )
    end
  end

  # add constraint to forbid both references set
  defp make_content_both_reference_constraint(_opts \\ []) do
    quote do
      Ecto.Migration.create_if_not_exists(
        Ecto.Migration.constraint(
          "bonfire_content",
          :mirror_or_upload_must_set_only_one,
          check: "content_mirror_id is null or content_upload_id is null"
        )
      )
    end
  end

  def drop_content_neither_reference_constraint(_opts \\ []) do
    drop_if_exists(Ecto.Migration.constraint(
          "bonfire_content", :mirror_or_upload_must_be_set))
  end

  def drop_content_both_reference_constraint(_opts \\ []) do
    drop_if_exists(Ecto.Migration.constraint(
          "bonfire_content", :mirror_or_upload_set_only_one))
  end

  defp mc(:up) do
    quote do
      unquote(make_content_table([]))
      unquote(make_content_neither_reference_constraint())
      unquote(make_content_both_reference_constraint())
    end
  end

  defp mc(:down) do
    quote do
      __MODULE__.drop_content_table()
      __MODULE__.drop_content_neither_reference_constraint()
      __MODULE__.drop_content_both_reference_constraint()
    end
  end

  defmacro migrate_content(dir), do: mc(dir)

  defmacro migrate_content() do
    quote do: migrate_content(Ecto.Migration.direction())
  end
end
