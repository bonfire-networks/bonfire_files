# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.ContentMirror do
  use Pointers.Pointable,
    otp_app: :bonfire_Files,
    table_id: "B0NF1REF11ESC0NTENTM1RR0R1",
    source: "bonfire_content_mirror"

  import Bonfire.Repo.Changeset, only: [validate_http_url: 2]
  alias Ecto.Changeset

  @type t :: %__MODULE__{}

  pointable_schema do
    field(:url, :string)
  end

  @cast ~w(url)a
  @required @cast

  def changeset(attrs) do
    %__MODULE__{}
    |> Changeset.cast(attrs, @cast)
    |> Changeset.validate_required(@required)
    |> Changeset.validate_length(:url, max: 4096)
    |> validate_http_url(:url)
  end
end

defmodule Bonfire.Files.ContentMirror.Migration do
  use Ecto.Migration
  import Pointers.Migration
  alias Bonfire.Files.ContentMirror

  defp make_content_mirror_table(exprs) do
    quote do
      require Pointers.Migration
      Pointers.Migration.create_pointable_table(ContentMirror) do
        Ecto.Migration.add(:url, :text, null: false)

        unquote_splicing(exprs)
      end
    end
  end

  defmacro create_content_mirror_table(), do: make_content_mirror_table([])
  defmacro create_content_mirror_table([do: {_, _, body}]),
    do: make_content_mirror_table(body)

  def drop_content_mirror_table(), do: drop_pointable_table(ContentMirror)

  defp mcm(:up), do: make_content_mirror_table([])
  defp mcm(:down) do
    quote do
      __MODULE__.drop_content_mirror_table()
    end
  end

  defmacro migrate_content_mirror(dir), do: mcm(dir)
  defmacro migrate_content_mirror() do
    quote do: migrate_content_mirror(Ecto.Migration.direction())
  end
end
