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
