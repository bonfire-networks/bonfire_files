defmodule Bonfire.Files.CapsuleIntegration.Attacher do
  import Untangle

  def upload(changeset, field, attrs) do
    changeset
    |> Capsule.Ecto.upload(attrs, [field], __MODULE__, :attach)
  end

  def attach({field, upload}, changeset) do
    debug(upload)

    # TODO: use prefix to put in right folder based on type/definition and user
    case Capsule.Storages.Disk.put(upload) do
      {:ok, id} ->
        Ecto.Changeset.cast(
          changeset,
          %{
            field => %{
              id: id,
              storage: Capsule.Storages.Disk
              # , metadata: %{extra: :here}
            }
          },
          [field]
        )

      error_tuple ->
        error(error_tuple)
        Ecto.Changeset.add_error(changeset, "Upload failed")
    end
  end
end
