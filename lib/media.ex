# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Media do
  use Needle.Pointable,
    otp_app: :bonfire_files,
    table_id: "30NF1REF11ESC0NTENT1SGREAT",
    source: "bonfire_files_media"

  use Bonfire.Common.Utils

  import Bonfire.Common.Config, only: [repo: 0]

  alias Ecto.Changeset
  alias Bonfire.Files.Media
  alias Bonfire.Files.Media.Queries

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  @behaviour Bonfire.Common.SchemaModule
  def schema_module, do: __MODULE__
  def context_module, do: __MODULE__
  def query_module, do: Queries

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module, do: ["Page"]

  @type t :: %__MODULE__{}

  pointable_schema do
    # has_one(:preview, __MODULE__)
    belongs_to(:creator, Needle.Pointer)

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

  @create_required ~w(path size media_type creator_id)a
  @cast @create_required ++ ~w(id metadata)a

  defp changeset(media \\ %__MODULE__{}, creator, attrs)

  defp changeset(media, creator, %{url: url} = attrs) when is_binary(url) do
    common_changeset(media, creator, attrs)
  end

  defp changeset(media, creator, attrs) do
    common_changeset(media, creator, attrs)
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

  def insert(creator, %{path: path} = file, file_info, attrs) do
    with {:ok, media} <- insert(creator, path, file_info, attrs) do
      {:ok, Map.put_new(media, :file, file)}
    end
  end

  def insert(creator, url_or_path, file_info, attrs) do
    metadata =
      Map.merge(
        Map.get(attrs, :metadata) || %{},
        Map.drop(file_info, [:id, :size, :media_type])
      )
      |> Enums.filter_empty(%{})

    attrs =
      attrs
      |> Map.put(:id, file_info[:id])
      |> Map.put_new(:file, url_or_path)
      |> Map.put(:path, url_or_path)
      |> Map.put(:size, file_info[:size])
      |> Map.put(:media_type, file_info[:media_type])
      |> Map.put(:module, file_info[:module])
      |> Map.put(:creator_id, Types.ulid(creator) || "0AND0MSTRANGERS0FF1NTERNET")
      |> Map.put(:metadata, metadata)

    with {:ok, media} <- repo().insert(changeset(creator, attrs)) do
      {:ok, Map.put(media, :creator, creator)}
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
           {:ok, deleted} <- module.delete({media.path, media.creator_id}) do
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

  def media_label(%{} = media) do
    (e(media.metadata, "label", nil) || e(media.metadata, "wikibase", "title", nil) ||
       e(media.metadata, "crossref", "title", nil) || e(media.metadata, "oembed", "title", nil) ||
       e(media.metadata, "facebook", "title", nil) ||
       e(media.metadata, "twitter", "title", nil) ||
       e(media.metadata, "other", "title", nil) ||
       e(media.metadata, "orcid", "title", "title", "value", nil))
    |> unwrap()
  end

  def description(%{} = media) do
    json_ld = e(media.metadata, "json_ld", nil)

    (e(json_ld, "description", nil) ||
       e(media.metadata, "facebook", "description", nil) ||
       e(media.metadata, "twitter", "description", nil) ||
       e(media.metadata, "other", "description", nil) ||
       e(json_ld, "headline", nil) ||
       e(media.metadata, "oembed", "abstract", nil))
    |> unwrap()
  end

  def unwrap(list) when is_list(list) do
    List.first(list)
    # |> unwrap()
  end

  def unwrap(other) do
    other
    # |> to_string()
  end

  def ap_publish_activity(subject, verb, media) do
    # media = repo().preload(media, [:replied, activity: [:tags]])
    # context = Threads.ap_prepare(Threads.ap_prepare(ulid(e(media, :replied, :thread_id, nil))))

    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: subject)

    # FIXME: don't assume public
    to = ["https://www.w3.org/ns/activitystreams#Public"]

    object = %{
      "type" => "Page",
      "actor" => actor.ap_id,
      "name" => media_label(media),
      "summary" => description(media),
      "url" => Bonfire.Common.Media.media_url(media),
      "to" => to
      # "context" => context,
      # "inReplyTo" => Threads.ap_prepare(ulid(e(media, :replied, :reply_to_id, nil)))
    }

    params = %{
      actor: actor,
      # context: context,
      object: object,
      to: to,
      pointer: ulid(media)
    }

    if verb == :edit, do: ActivityPub.update(params), else: ActivityPub.create(params)
  end

  def ap_receive_activity(creator, activity, object) do
    error("TODO")
  end
end
