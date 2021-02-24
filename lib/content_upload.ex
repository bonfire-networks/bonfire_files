# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ContentUpload do
  use Pointers.Pointable,
    otp_app: :bonfire_files,
    table_id: "B0NF1REF11ESC0NTENTVP10AD1",
    source: "bonfire_content_upload"

  alias Ecto.Changeset

  @type t :: %__MODULE__{}

  pointable_schema do
    field(:path, :string)
    field(:size, :integer)
  end

  @cast ~w(path size)a
  @required @cast

  def changeset(attrs) do
    %__MODULE__{}
    |> Changeset.cast(attrs, @cast)
    |> Changeset.validate_required(@required)
  end
end

defmodule Bonfire.Files.ContentUpload.Migration do
  use Ecto.Migration
  import Pointers.Migration
  alias Bonfire.Files.ContentUpload

  defp make_content_upload_table(exprs) do
    quote do
      require Pointers.Migration
      Pointers.Migration.create_pointable_table(ContentUpload) do
        Ecto.Migration.add(:path, :text, null: false)
        Ecto.Migration.add(:size, :integer, null: false)

        unquote_splicing(exprs)
      end
    end
  end

  defmacro create_content_upload_table(), do: make_content_upload_table([])
  defmacro create_content_upload_table([do: {_, _, body}]),
    do: make_content_upload_table(body)

  def drop_content_upload_table(), do: drop_pointable_table(ContentUpload)

  defp mcu(:up), do: make_content_upload_table([])
  defp mcu(:down) do
    quote do
      __MODULE__.drop_content_upload_table()
    end
  end

  defmacro migrate_content_upload(dir), do: mcu(dir)

  defmacro migrate_content_upload() do
    quote do: migrate_content_upload(Ecto.Migration.direction())
  end
end
