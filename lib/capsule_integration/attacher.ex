defmodule Bonfire.Files.CapsuleIntegration.Attacher do
  import Untangle
  use Bonfire.Common.Config

  def storages(upload, Bonfire.Files.FaviconStore) do
    [
      cache: Entrepot.Storages.Disk,
      store: Entrepot.Storages.Disk
    ]
  end

  def storages(upload, module) do
    # IO.inspect(upload, label: "uuuu")
    # IO.inspect(module, label: "mmmm")

    if Config.get([:bonfire_files, :storage], :local) == :s3 do
      [
        cache: Entrepot.Storages.Disk,
        store: Entrepot.Storages.S3
      ]
    else
      [
        cache: Entrepot.Storages.Disk,
        store: Entrepot.Storages.Disk
      ]
    end
  end

  def upload(changeset, field, %{module: module} = attrs)
      when is_atom(module) and not is_nil(module) do
    changeset
    |> debug()
    |> Entrepot.Ecto.upload(attrs, [field], module, :attach)
  end

  def upload(changeset, field, attrs) do
    changeset
    |> debug()

    # |> Entrepot.Ecto.upload(attrs, [field], __MODULE__, :attach)
    # TODO: also use Entrepot for when we don't have a definition?
  end

  def attach(upload, changeset, module \\ nil)

  def attach({field, upload}, changeset, module) do
    debug(upload, module)

    # Get media_type from changeset attrs
    media_type = Ecto.Changeset.get_change(changeset, :media_type)

    # TODO: use prefix to put in right folder based on type/definition and user
    case store(module, upload, changeset, media_type) do
      {:ok, %Entrepot.Locator{} = locator} ->
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

  def store(module, upload, changeset, media_type \\ nil)

  def store(module, upload, changeset, media_type) when is_atom(module) and not is_nil(module) do
    # debug(upload, "store: #{module}")

    content_type = media_type
    # |> debug("Attacher content_type")

    module.store(upload, :store,
      creator_id: Ecto.Changeset.get_change(changeset, :creator_id) |> debug(),
      content_type: content_type
    )
  end

  # def store(_, upload, _, _) when is_binary(upload), do: store(nil, URI.parse(upload), nil)
  def store(_, upload, _, _) do
    case Entrepot.Storages.Disk.put(upload) do
      {:ok, id} ->
        debug(id)

        {:ok,
         %Entrepot.Locator{
           id: id,
           storage: Entrepot.Storages.Disk
           # , metadata: %{extra: :here}
         }}

      error ->
        error
    end
  end
end
