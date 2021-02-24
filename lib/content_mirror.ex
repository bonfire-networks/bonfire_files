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
