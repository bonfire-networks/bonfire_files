defmodule Bonfire.Files.CapsuleIntegration.Attacher do
  import Untangle
  alias Bonfire.Common.Config

  def storages(upload, module) do
    debug(upload)
    debug(module)

    if Config.get([:bonfire_files, :storage], :local) == :s3 do
      [
        cache: Capsule.Storages.Disk,
        store: Capsule.Storages.S3
      ]
    else
      [
        cache: Capsule.Storages.Disk,
        store: Capsule.Storages.Disk
      ]
    end
  end

  def upload(changeset, field, %{module: module} = attrs) when is_atom(module) and not is_nil(module) do
    changeset
    |> debug()
    |> Capsule.Ecto.upload(attrs, [field], module, :attach)
  end

  def upload(changeset, field, attrs) do
    changeset
    |> debug()
    |> Capsule.Ecto.upload(attrs, [field], __MODULE__, :attach)
  end

  def attach(upload, changeset, module \\ nil)

  def attach({field, upload}, changeset, module) do
    debug(upload, module)

    # TODO: use prefix to put in right folder based on type/definition and user
    case store(module, upload, changeset) do
      {:ok, %Capsule.Locator{} = locator} ->
        debug(locator)

        Ecto.Changeset.cast(
          changeset,
          %{
            field => locator
          },
          [field]
        )

      {:error, error} when is_binary(error) or is_atom(error) ->
        error(upload, error)
        Ecto.Changeset.add_error(changeset, field, "Upload failed: #{error}")

      error ->
        error(error)
        Ecto.Changeset.add_error(changeset, field, "Upload failed")
    end
  end

  def store(module, upload, changeset) when is_atom(module) and not is_nil(module) do
    debug(module)

    module.store(upload, :store,
      user_id: Ecto.Changeset.get_change(changeset, :user_id) |> debug()
    )
  end

  def store(_, upload, _) do
    case Capsule.Storages.Disk.put(upload) do
      {:ok, id} ->
        debug(id)

        {:ok,
         %Capsule.Locator{
           id: id,
           storage: Capsule.Storages.Disk
           # , metadata: %{extra: :here}
         }}

      error ->
        error
    end
  end
end
