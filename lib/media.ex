# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Media do
  use Needle.Pointable,
    otp_app: :bonfire_files,
    table_id: "30NF1REF11ESC0NTENT1SGREAT",
    source: "bonfire_files_media"

  use Bonfire.Common.Utils

  import Bonfire.Common.Config, only: [repo: 0]
  import Ecto.Query, only: [select: 3]

  alias Ecto.Changeset
  alias Bonfire.Files
  alias Bonfire.Files.Media
  alias Bonfire.Files.Media.Queries

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  @behaviour Bonfire.Common.SchemaModule
  def schema_module, do: __MODULE__
  def context_module, do: __MODULE__
  def query_module, do: Queries

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  # NOTE: Page objects are a reference to an external resource (eg. a link or media) as as opposed to an Article object which comes with contents.
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
    cs =
      common_changeset(media, creator, attrs)
      |> upload_changeset(attrs)

    Changeset.cast(cs, %{path: Bonfire.Common.Media.media_url(cs.changes)}, @cast)
  end

  defp common_changeset(media, _user, attrs) do
    base_changeset(media, attrs)
    |> Changeset.validate_required(@create_required)
    |> Changeset.validate_length(:media_type, max: 255)

    # |> debug()
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
    meta_attrs = Map.get(attrs, :metadata) || %{}

    metadata =
      Map.merge(
        meta_attrs,
        file_info || %{}
      )
      |> Map.drop([:id, :size, :media_type])
      |> Enums.filter_empty(%{})

    attrs =
      attrs
      |> Map.put(:id, file_info[:id])
      |> Map.put_new(:file, url_or_path)
      |> Map.put(:path, url_or_path)
      |> Map.put(:size, file_info[:size])
      |> Map.put(
        :media_type,
        meta_attrs[:media_type] || attrs[:media_type] || file_info[:media_type]
      )
      |> Map.put(:module, file_info[:module])
      |> Map.put(:creator_id, Types.uid(creator) || "0AND0MSTRANGERS0FF1NTERNET")
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
  def hard_delete(module \\ nil, %Media{} = media) do
    repo().transaction(fn ->
      with {:ok, media} <- repo().delete(media),
           {:ok, deleted} <-
             Files.delete_files(module, media |> debug("sddssd"), creator_id: media.creator_id)
             |> debug("deletttt") do
        {:ok, deleted}
      end
    end)
  end

  @doc false
  def hard_delete_soft_deleted_files() do
    hard_delete_by(deleted: true)
  end

  defp hard_delete_by(filters) do
    {_num, list} =
      Queries.query(Media)
      |> select([c], c)
      |> Queries.filter(filters)
      |> repo().delete_all()

    # FIXME: doesn't cleanup files
    list
    |> Enum.map(&Files.delete_files/1)
  end

  def media_label(%{metadata: metadata} = _media), do: media_label(metadata)

  def media_label(%{} = metadata) do
    case (e(metadata, "label", nil) || e(metadata, "wikibase", "title", nil) ||
            e(metadata, "crossref", "title", nil) || e(metadata, "oembed", "title", nil) ||
            e(metadata, "json_ld", "name", nil) ||
            e(metadata, "facebook", "title", nil) ||
            e(metadata, "twitter", "title", nil) ||
            e(metadata, "other", "title", nil) ||
            e(metadata, "orcid", "title", "title", "value", nil))
         |> unwrap() do
      "Just a moment" <> _ -> nil
      other -> other
    end
  end

  def description(%{metadata: metadata} = _media), do: description(metadata)

  def description(%{} = metadata) do
    json_ld = e(metadata, "json_ld", nil)

    (e(json_ld, "description", nil) ||
       e(metadata, "facebook", "description", nil) ||
       e(metadata, "twitter", "description", nil) ||
       e(metadata, "other", "description", nil) ||
       e(json_ld, "headline", nil) || ed(json_ld, "attachment", "name", nil) ||
       e(metadata, "oembed", "abstract", nil))
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
    # context = Threads.ap_prepare(Threads.ap_prepare(uid(e(media, :replied, :thread_id, nil))))

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
      # "inReplyTo" => Threads.ap_prepare(uid(e(media, :replied, :reply_to_id, nil)))
    }

    params = %{
      actor: actor,
      # context: context,
      object: object,
      to: to,
      pointer: uid(media)
    }

    if verb == :edit, do: ActivityPub.update(params), else: ActivityPub.create(params)
  end

  def ap_receive_activity(
        creator,
        activity,
        %{data: %{"image" => %{"url" => media_url}} = object} = _ap_object
      ) do
    debug(activity, "activity")
    warn(object, "WIP")

    with {:ok, media} <-
           Bonfire.Files.Media.insert(
             creator,
             media_url,
             %{media_type: e(object, "image", "type", nil), size: 0},
             %{metadata: %{json_ld: object}}
           )
           |> debug(),
         {:ok, activity} <-
           Bonfire.Social.Objects.publish(
             creator,
             :create,
             media,
             [boundary: "public"],
             __MODULE__
           )
           |> debug() do
      {:ok, activity}
    end
  end

  # def ap_receive_activity(_creator, activity, %{data: %{"some_other_media"=>%{"url"=> media_url}}} = object) do
  #   debug(activity, "activity")
  #   warn(object, "WIP")

  #   Bonfire.Files.Acts.URLPreviews.maybe_fetch_and_save(
  #           user,
  #           e(summary, "url", "value", nil) || "https://orcid.org/#{e(summary, "path", nil)}",
  #           opts
  #           #  to upsert metadata
  #           |> Keyword.put_new(:update_existing, true)
  #           # to (re)publish the activity
  #           # |> Keyword.put_new(:update_existing, :force)
  #           |> Keyword.merge(
  #             id:
  #               DatesTimes.maybe_generate_ulid(
  #                 # e(summary, "publication-date", nil) ||
  #                 e(summary, "created-date", "value", nil)
  #               ),
  #             post_create_fn: fn current_user, media, opts ->
  #               Bonfire.Social.Objects.publish(
  #                 current_user,
  #                 :create,
  #                 media,
  #                 [boundary: "public"],
  #                 __MODULE__
  #               )
  #             end,
  #             extra: %{orcid: summary}
  #           )
  #         )
  # end

  def ap_receive_activity(creator, activity, object) do
    debug(activity, "activity")
    warn(object, "WIP: could not find media in the Page, so save as Note")
    maybe_apply(Bonfire.Posts, :ap_receive_activity, [creator, activity, object])
  end
end
