# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Files.Media do
  use Needle.Pointable,
    otp_app: :bonfire_files,
    table_id: "30NF1REF11ESC0NTENT1SGREAT",
    source: "bonfire_files_media"

  use Bonfire.Common.Utils

  import Bonfire.Common.Config, only: [repo: 0]
  import Ecto.Query, only: [select: 3]
  import ActivityPub.Config, only: [is_in: 2]

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
  def federation_module, do: ["Page", "Video", "Image", "Document", "PodcastEpisode", "Audio"]

  # @type t :: %__MODULE__{}

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

    case Bonfire.Files.remote_url(nil, cs.changes, nil, cache: false) do
      "http" <> _ = url ->
        #  NOTE: need to avoid storing expiring presigned URLs in DB
        Changeset.cast(cs, %{path: nil}, @cast)

      url when is_binary(url) ->
        Changeset.cast(cs, %{path: url}, @cast)

      _ ->
        # dunno
        cs
    end
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
        # use the first non-blank media_type from any source; fall back to "remote" only when none
        # provide one (e.g. a still-transcoding PeerTube Video with no playable file). See #1728.
        # TODO: re-fetch such pending/transcoding objects later so they resolve to the real media:
        # https://github.com/bonfire-networks/bonfire-app/issues/2070
        Enums.filter_empty(meta_attrs[:media_type], nil) ||
          Enums.filter_empty(attrs[:media_type], nil) ||
          Enums.filter_empty(file_info[:media_type], nil) || "remote"
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
      |> repo().delete_many()

    # FIXME: doesn't cleanup files
    list
    |> Enum.map(&Files.delete_files/1)
  end

  def media_label(%{metadata: metadata} = _media), do: media_label(metadata)

  # NOTE: reads from `json_ld` use `ed` rather than the `e` macro: JSON-LD arrives as an array as often as a single object (`@graph`, or a page describing several entities — which is why `Files.is_research?/2` handles both), and only `ed` searches into a list for a key. `e` asks Pathex for a path, and Pathex can't index a list by a string key.
  def media_label(%{} = metadata) do
    json_ld = e(metadata, "json_ld", nil)

    case (e(metadata, "label", nil) || e(metadata, :label, nil) || e(metadata, "title", nil) ||
            e(metadata, "wikibase", "title", nil) ||
            e(metadata, "crossref", "title", nil) || e(metadata, "oembed", "title", nil) ||
            ed(json_ld, "name", nil) ||
            ed(json_ld, "attachment", "name", nil) ||
            e(metadata, "atom", "title", nil) || e(metadata, "rss", "title", nil) ||
            e(metadata, "facebook", "title", nil) ||
            e(metadata, "twitter", "title", nil) ||
            e(metadata, "other", "title", nil) ||
            e(metadata, "orcid", "title", "title", nil) ||
            e(metadata, "zenodo", "title", nil) ||
            e(metadata, "rss", "channel", "title", nil))
         |> unwrap() do
      "Just a moment" <> _ -> nil
      %{"value" => value} -> value
      other -> other
    end
  end

  def media_label(_), do: nil

  @doc """
  The author-provided alt text of a media (what an image shows), which is also what AS2 puts in an attachment's `name`.

  Greedy (the default) falls back to the label, since a caption still describes the media better than nothing.
  """
  def media_alt(media, greedy? \\ true)
  def media_alt(%{metadata: metadata} = _media, greedy?), do: media_alt(metadata, greedy?)
  def media_alt(metadata, false), do: e(metadata, "alt", nil)

  def media_alt(metadata, _true),
    do: media_alt(metadata, false) || media_label(metadata) |> Bonfire.Common.Text.text_only()

  def media_label_and_alt(media) do
    [
      media_label(media) |> Bonfire.Common.Text.text_only(),
      media_alt(media, false) |> Bonfire.Common.Text.text_only()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(" — ")
    |> case do
      "" -> nil
      combined -> combined
    end
  end

  def description(%{metadata: metadata} = _media), do: description(metadata)

  # see the NOTE on `media_label/2` for why `json_ld` is read with `ed` rather than `e`
  def description(%{} = metadata) do
    json_ld = e(metadata, "json_ld", nil)

    # A user-supplied description (e.g. set via `uploadMedia`) is stored at the top level; check it before falling back to fetched OG/oEmbed metadata.
    # AS2 `summary` is the object's own precis, and what we send ourselves when a link Media federates as a `Page`
    (e(metadata, "description", nil) ||
       ed(json_ld, "description", "content", nil) || ed(json_ld, "description", nil) ||
       ed(json_ld, "summary", nil) ||
       e(metadata, "facebook", "description", nil) ||
       e(metadata, "twitter", "description", nil) ||
       e(metadata, "rss", "description", nil) ||
       e(metadata, "other", "description", nil) ||
       ed(json_ld, "headline", nil) ||
       e(metadata, "oembed", "abstract", nil) ||
       e(metadata, "atom", "summary", "value", nil) ||
       e(metadata, "rss", "channel", "description", nil) ||
       ed(json_ld, "content", nil) ||
       e(metadata, "atom", "content", "value", nil))
    |> unwrap()
  end

  def description(_), do: nil

  @doc """
  URL of the cover image for a media, resolved from the metadata we fetched for it.

  Returns nil when the only candidate is the site's favicon (see `reject_site_icon/2`).
  """
  def preview_image_url(media) do
    metadata_image_url(media)
    |> unwrap()
    |> reject_site_icon(media)
  end

  @doc """
  The cover image a media's metadata offers, in preference order, before `preview_image_url/1` vets it.

  Callers that have their own fallback (a UI that can show the media itself) use this and vet the result themselves.
  """
  def metadata_image_url(%{media: %{id: _} = media}), do: metadata_image_url(media)

  def metadata_image_url(%{} = media) do
    # tile images are often good previews; OG images are sometimes nested; an AP `icon` can be one object or an array (eg. PeerTube); `json_ld` covers PeerTube videos and `preview` covers Mastodon ones
    # `ed`, since AS2 lets `image` be an array of Images and returning the Image object rather than its url would hand back a map where a URL string is expected
    # a received AS2 object keeps its cover under `json_ld`, since that is where the whole object is stored
    e(media, :metadata, "oembed", "thumbnail_url", nil) ||
      e(media, :metadata, "twitter", "image", nil) ||
      (e(media, :metadata, "facebook", "image", "url", nil) ||
         e(media, :metadata, "facebook", "image", nil)) ||
      ed(media, :metadata, "image", "url", nil) ||
      e(media, :metadata, "image", nil) ||
      extract_ap_icon_url(ed(media, :metadata, "json_ld", "image", nil)) ||
      extract_ap_icon_url(e(media, :metadata, "icon", nil)) ||
      extract_ap_icon_url(ed(media, :metadata, "json_ld", "icon", nil)) ||
      extract_ap_icon_url(e(media, :metadata, "preview", nil)) ||
      e(media, :metadata, "other", "msapplication-TileImage", nil) ||
      e(media, :metadata, "other", "apple-touch-icon", nil) ||
      e(media, :metadata, "other", "og:image", nil) ||
      e(media, :metadata, "other", "og:image:url", nil) ||
      Bonfire.Common.Media.thumbnail_url(media)
  end

  def metadata_image_url(_), do: nil

  @doc """
  Discard a candidate cover image that is really the site's favicon.

  Some sites publish their favicon as `og:image`; keeping the distinction lets link cards use the compact favicon layout rather than stretching an icon into a cover.
  """
  def reject_site_icon(preview, media) when is_binary(preview) do
    favicon =
      media
      |> e(:metadata, "favicon", nil)
      |> unwrap()

    if preview == favicon, do: nil, else: preview
  end

  def reject_site_icon(preview, _media), do: preview

  # an ActivityPub `icon` can be a single object or an array
  defp extract_ap_icon_url(icons) when is_list(icons) do
    # pick the largest, for the best quality thumbnail
    icons
    |> Enum.filter(&is_map/1)
    |> Enum.max_by(fn icon -> (icon["width"] || 0) * (icon["height"] || 0) end, fn -> nil end)
    |> extract_ap_icon_url()
  end

  defp extract_ap_icon_url(%{"url" => url}) when is_binary(url), do: url
  defp extract_ap_icon_url(%{"href" => url}) when is_binary(url), do: url
  defp extract_ap_icon_url(url) when is_binary(url), do: url
  defp extract_ap_icon_url(_), do: nil

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

    # Address from the object's boundaries rather than assuming public. `publish/3` is only reached for an EXPLICIT publish carrying an intentional boundary (the GraphQL caller requires `to_boundary`/`to_circles`), so media that was never published is unaffected — it never federated.
    is_public = Bonfire.Boundaries.object_public?(media)

    object = %{
      # Pin the AP `id` to this instance's canonical object URL so it matches the
      # host that serves it. Without this, normalisation falls back to `url` (the
      # external article URL for an embedded-comments Media), producing an
      # id/host mismatch that remote servers reject on fetch.
      "id" => ActivityPub.Object.object_url(uid(media)),
      "type" => "Page",
      "actor" => actor.ap_id,
      # Mastodon & co. read authorship from `attributedTo` on the object, not from `actor`
      "attributedTo" => actor.ap_id,
      "name" => media_label_and_alt(media),
      "summary" => description(media),
      "url" => Bonfire.Common.Media.media_url(media)
      # addressing (`to`/`cc`/`bcc`/`audience`) is applied below, for the activity and this object together, so neither can be forgotten
      # "context" => context,
      # "inReplyTo" => Threads.ap_prepare(uid(e(media, :replied, :reply_to_id, nil)))
    }

    object =
      object
      # the cover image we already resolved, so a receiver has something to render without fetching the origin
      |> Enums.maybe_put("image", Files.ap_image_object(preview_image_url(media)))

    params =
      %{
        actor: actor,
        # context: context,
        object: object,
        pointer: uid(media)
      }
      # to/cc/bcc/audience, on the activity and the object, in one place
      |> Bonfire.Federate.ActivityPub.AdapterUtils.put_addressing(subject, media, is_public)

    if verb == :edit, do: ActivityPub.update(params), else: ActivityPub.create(params)
  end

  # handle images from Lemmy and the like
  def ap_receive_activity(
        creator,
        activity,
        %{data: %{"type" => "Page", "image" => %{"url" => media_url}} = object_data} = ap_object
      ) do
    debug(activity, "activity")
    warn(object_data, "WIP - for lemmy 'Page' links")

    {boundary, to_circles} =
      Bonfire.Federate.ActivityPub.AdapterUtils.incoming_boundary_circles(activity, ap_object)

    with {:ok, activity} <-
           create_and_publish(
             creator,
             media_url || object_data["id"],
             e(object_data, "image", "type", nil),
             0,
             %{json_ld: object_data},
             #  TODO: boundary should be computed like for Posts
             boundary: boundary,
             to_circles: to_circles
           ) do
      {:ok, activity}
    end
  end

  # handle Audio from Funkwhale, etc
  def ap_receive_activity(
        creator,
        activity,
        %{data: %{"type" => audio_type, "url" => urls} = object_data} = ap_object
      )
      when is_in(audio_type, ["Audio", "PodcastEpisode"]) and
             (is_list(urls) or is_binary(urls) or is_map(urls)) do
    # debug(activity, "activity")
    debug(object_data, "Funkwhale audio")

    {boundary, to_circles} =
      Bonfire.Federate.ActivityPub.AdapterUtils.incoming_boundary_circles(activity, ap_object)
      |> debug("incoming_boundary_circles")

    with {media_url, size, media_type} <- extract_audio_url(urls),
         {:ok, activity} <-
           create_and_publish(
             creator,
             media_url || object_data["id"],
             media_type,
             size,
             %{json_ld: object_data},
             boundary: boundary,
             to_circles: to_circles
           ) do
      {:ok, activity}
    end
  end

  def ap_receive_activity(
        creator,
        activity,
        %{data: %{"type" => audio_type, "audio" => %{"url" => urls}} = object_data} = ap_object
      )
      when is_in(audio_type, ["Audio", "PodcastEpisode"]) and
             (is_list(urls) or is_binary(urls) or is_map(urls)) do
    ap_receive_activity(
      creator,
      activity,
      %{ap_object | data: Map.put(ap_object.data, "url", urls)}
    )
  end

  # handle Video from Peertube
  def ap_receive_activity(
        creator,
        activity,
        %{data: %{"type" => "Video", "url" => urls} = object_data} = ap_object
      )
      when is_list(urls) or is_binary(urls) or is_map(urls) do
    # debug(activity, "activity")
    debug(object_data, "PeerTube video")

    {boundary, to_circles} =
      Bonfire.Federate.ActivityPub.AdapterUtils.incoming_boundary_circles(activity, ap_object)
      |> debug("incoming_boundary_circles")

    # Find the highest quality video URL
    with {media_url, size, media_type} <- extract_best_video_url(urls),
         {:ok, activity} <-
           create_and_publish(
             creator,
             media_url || object_data["id"],
             media_type,
             size,
             %{json_ld: object_data},
             boundary: boundary,
             to_circles: to_circles
           ) do
      {:ok, activity}
    end
  end

  # TODO for Bookwyrm, etc
  # def ap_receive_activity(_creator, activity, %{data: %{"some_other_media"=>%{"url"=> media_url}}} = object) do
  #   debug(activity, "activity")
  #   warn(object, "WIP")

  #   Bonfire.Files.maybe_fetch_and_save(
  #           user,
  #           e(summary, "url", "value", nil) || "https://orcid.org/#{e(summary, "path", nil)}",
  #           opts
  #           #  to upsert metadata
  #           |> Keyword.put_new(:update_existing, true)
  #           # to (re)publish the activity
  #           # |> Keyword.put_new(:update_existing, :force)
  #           |> Keyword.merge(
  #             id:
  #               DatesTimes.generate_ulid_if_past(
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

  def ap_receive_activity(creator, activity, %{data: %{"type" => "Page"}} = object) do
    debug(activity, "activity")

    warn(
      object,
      "WIP: could not recognise a Lemmy style image in this Page, so save as Post (possibly with Media as attachment)"
    )

    maybe_apply(Bonfire.Posts, :ap_receive_activity, [creator, activity, object])
  end

  def ap_receive_activity(creator, activity, object) do
    debug(activity, "activity")
    warn(object, "WIP: could not recognise media, so save as APActivities")
    maybe_apply(Bonfire.Social.APActivities, :ap_receive_activity, [creator, activity, object])
  end

  def create_and_publish(
        creator,
        media_url,
        media_type,
        size,
        metadata,
        opts
      ) do
    # Find the highest quality video URL
    with {:ok, media} <-
           insert(
             creator,
             media_url,
             %{
               media_type: media_type,
               size: size || 0
             },
             %{metadata: metadata, url: media_url}
           )
           |> debug("created"),
         {:ok, activity} <-
           publish(
             creator,
             media,
             opts
           ) do
      {:ok, activity}
    end
  end

  def publish(
        creator,
        media,
        opts
      ) do
    with {:ok, activity} <-
           Bonfire.Social.Objects.publish(
             creator,
             :create,
             media,
             opts,
             __MODULE__
           )
           |> debug("published") do
      maybe_tag(creator, media, opts)

      {:ok, activity}
    end
  end

  # Media runs no epic, so `Bonfire.Tag.Acts.Tag` never sees it: without this, media carries no tags
  # and never reaches the feed of a group it was published in, unlike a post carrying the same file.
  # `maybe_tag/4` does both — it tags the object and auto-boosts whichever tags are categories, with
  # the same `:tag` permission check, and is meant to be called outside an epic.
  defp maybe_tag(creator, media, opts) do
    tags =
      List.wrap(opts[:tags]) ++
        List.wrap(opts[:publish_in] || opts[:context_id])

    if tags != [] do
      Utils.maybe_apply(Bonfire.Tag, :maybe_tag, [creator, media, tags], fallback_return: nil)
      |> debug("tagged the media")
    end
  end

  defp extract_audio_url(urls) do
    urls
    |> List.wrap()
    |> Enum.filter(fn url ->
      # Filter for direct audio links (excluding torrents, magnets and HLS fragments)
      # and Files.has_extension?(url, ".mp3") TODO: check file extension if we don't have a mime type
      is_binary(url) or
        (is_map(url) and
           String.starts_with?(url["mediaType"] || url["mimeType"] || "", "audio/"))
    end)
    |> List.first()
    |> case do
      # TODO: consolidate to using only mediaType or mimeType in AP Transformer
      %{"href" => href, "size" => size, "mediaType" => media_type}
      when is_binary(href) and is_integer(size) and is_binary(media_type) ->
        {href, size, media_type}

      %{"href" => href, "size" => size, "mimeType" => media_type}
      when is_binary(href) and is_integer(size) and is_binary(media_type) ->
        {href, size, media_type}

      %{"href" => href, "mediaType" => media_type}
      when is_binary(href) and is_binary(media_type) ->
        {href, 0, media_type}

      %{"href" => href, "mimeType" => media_type}
      when is_binary(href) and is_binary(media_type) ->
        {href, 0, media_type}

      %{"href" => href} when is_binary(href) ->
        # Default to mp3 if no media type specified?
        {href, 0, "audio/mp3"}

      href when is_binary(href) ->
        # Default to mp3 if no media type specified?
        {href, 0, "audio/mp3"}

      _ ->
        {nil, 0, nil}
    end
  end

  # Helper to extract the highest quality video URL, size and media type from PeerTube "url" array
  defp extract_best_video_url(urls) do
    urls = List.wrap(urls)

    # Newer PeerTube versions no longer list progressive `.mp4` files at the top
    # level: the top-level `url` only has the HTML watch page and the HLS master
    # playlist (`application/x-mpegURL`), and the actual `video/mp4` links live
    # inside that playlist entry's `tag` array. So consider both the top-level
    # entries AND any nested `tag` entries as candidates.
    nested = Enum.flat_map(urls, fn url -> List.wrap(is_map(url) && url["tag"]) end)

    (urls ++ nested)
    |> Enum.filter(fn url ->
      # Direct video links (mediaType video/*), or a bare string URL
      is_binary(url) or
        (is_map(url) &&
           String.starts_with?(url["mediaType"] || url["mimeType"] || "", "video/"))
    end)
    |> Enum.sort_by(fn url ->
      # Prefer progressive files over HLS fragments, then highest resolution.
      href = (is_map(url) && url["href"]) || url

      fragment? =
        is_binary(href) and String.contains?(href, ["-fragmented.mp4", "streaming-playlists"])

      {if(fragment?, do: 1, else: 0), -((is_map(url) && url["height"]) || 0)}
    end)
    |> List.first()
    |> case do
      # TODO: consolidate to using only mediaType or mimeType in AP Transformer
      %{"href" => href, "size" => size, "mediaType" => media_type}
      when is_binary(href) and is_integer(size) and is_binary(media_type) ->
        {href, size, media_type}

      %{"href" => href, "size" => size, "mimeType" => media_type}
      when is_binary(href) and is_integer(size) and is_binary(media_type) ->
        {href, size, media_type}

      %{"href" => href, "mediaType" => media_type}
      when is_binary(href) and is_binary(media_type) ->
        {href, 0, media_type}

      %{"href" => href, "mimeType" => media_type}
      when is_binary(href) and is_binary(media_type) ->
        {href, 0, media_type}

      %{"href" => href} when is_binary(href) ->
        # Default to mp4 if no media type specified
        {href, 0, "video/mp4"}

      href when is_binary(href) ->
        # Default to mp4 if no media type specified
        {href, 0, "video/mp4"}

      _ ->
        # No direct/nested video file: fall back to the HLS master playlist so
        # the video is still ingested with a usable (non-nil) media_type, instead
        # of failing the `media_type: can't be blank` changeset and leaving an
        # orphaned/untitled object (bonfire-app#1728 / #1774 / #1715).
        case find_hls_playlist(urls) do
          {href, media_type} when is_binary(href) -> {href, 0, media_type}
          _ -> {nil, 0, nil}
        end
    end
  end

  # Find the HLS master playlist (m3u8) link among the url entries, if any.
  defp find_hls_playlist(urls) do
    urls
    |> List.wrap()
    |> Enum.find_value(fn
      %{"href" => href, "mediaType" => "application/x-mpegURL"} when is_binary(href) ->
        {href, "application/x-mpegURL"}

      %{"href" => href, "mimeType" => "application/x-mpegURL"} when is_binary(href) ->
        {href, "application/x-mpegURL"}

      _ ->
        nil
    end)
  end

  # Helper to find the size of the selected video
  defp find_video_size(urls, selected_url) when is_list(urls) and is_binary(selected_url) do
    urls
    |> Enum.find(fn url -> url["href"] == selected_url end)
    |> case do
      %{"size" => size} when is_integer(size) -> size
      _ -> 0
    end
  end

  def maybe_fetch_and_save(current_user, url, opts \\ [])

  def maybe_fetch_and_save(current_user, urls, opts) when is_list(urls) do
    # TODO: optimise by using Unfurl.apply_many instead? or use async_stream here
    urls
    |> Enum.map(&maybe_fetch_and_save(current_user, &1, opts))
  end

  def maybe_fetch_and_save(current_user, url, opts) when is_binary(url) do
    # `get_by_url/1` rather than `get_by_path/1`: the dedup has to catch the variants a URL arrives as (tracking params, trailing slash, a previously-recorded source url) BEFORE we unfurl, or a link that already came to us with its metadata gets fetched again when the same URL shows up in the post body.
    with {:error, :not_found} <- get_by_url(url) do
      do_maybe_fetch_and_save(current_user, url, opts)
    else
      {:ok, media} ->
        # already exists
        if opts[:update_existing] == :force do
          do_maybe_fetch_and_save(current_user, url, opts)
        else
          media
        end

      other ->
        error(other, "Could not check existing media")
        nil
    end
  end

  defp do_maybe_fetch_and_save(current_user, url, opts) do
    # Pass our AP-aware fetch function to unfurl so it runs in parallel with oembed
    pid = self()
    instance_meta = Bonfire.Common.TestInstanceRepo.get_parent_instance_meta()

    opts =
      Keyword.put(opts, :fetch_html_fn, fn url, opts ->
        # Preserve multi-tenancy/context in spawned process
        Bonfire.Common.TestInstanceRepo.set_child_instance(pid, instance_meta)
        ap_aware_fetch(url, opts)
      end)

    if(opts[:fetch_fn], do: opts[:fetch_fn].(url, opts), else: Unfurl.unfurl(url, opts))
    |> case do
      {:ok, object} when is_struct(object) ->
        # eg. we got a quoted AP object
        object

      {:ok, %{} = meta} ->
        maybe_save(current_user, url, meta, opts)

      other ->
        error(other, "Could not fetch URL preview")
        nil
    end
  catch
    e ->
      # workaround for badly-parsed webpages in non-UTF8 encodings
      error(e, "Could not save the URL preview")
      nil
  rescue
    e ->
      # A failed URL preview must never fail the whole publish for a user (an exception from unfurl's favicon lookup was doing exactly that). `err/2` rather than `error/2` because it raises in `:test` and only logs in dev/prod — so the underlying bug still fails the suite instead of being silently swallowed.
      err(e, "Could not save the URL preview")
      nil
  end

  # Resolve a (possibly relative) canonical url against the original fetched url, so a relative `<link rel="canonical" href="/path">` becomes an absolute url instead of being stored host-less. Absolute canonical urls are returned unchanged.
  defp resolve_canonical_url(url, canonical) when is_binary(canonical) and canonical != "" do
    if is_binary(url) and url != "" do
      URI.merge(url, canonical) |> to_string()
    else
      canonical
    end
  rescue
    _ -> canonical
  end

  defp resolve_canonical_url(_url, _canonical), do: nil

  def maybe_save(current_user, url, meta, opts \\ []) do
    # note: canonical url is only set if different from original url, so we only check each unique url once. We resolve it against the original url since sites sometimes serve a relative `<link rel="canonical">` (which would otherwise be stored host-less and later rendered as `http:///path`)
    # normalize away tracking params so `?utm=…`/`?fbclid=…` variants of one page collapse to one Media
    url = Bonfire.Common.URIs.strip_tracking_params(url)
    canonical_url = resolve_canonical_url(url, Map.get(meta, :canonical_url))

    # the canonical stays the primary `path` (the stable identity); the varying source url is recorded
    # in `metadata["urls"]` so `get_by_url/1` can find this Media by it (when it isn't the `path`)
    url_main_key = canonical_url || url

    with media_type <-
           if(opts[:type_fn],
             do: opts[:type_fn].(meta),
             else: Files.link_type(url, meta)
           ),
         extra <- %{
           url: url,
           media_type: media_type,
           metadata:
             Enums.deep_merge(
               opts[:extra] || %{},
               meta
               |> Map.drop([:canonical_url])
               |> Enums.filter_empty(%{})
             )
             # record the source url so `get_by_url/1` can find this Media by it, when it isn't already
             # the primary `path` (the canonical) — a jsonb list, appended on later dedup-hits
             |> maybe_put_source_url(url, url_main_key)
         },
         # dedup by the canonical `path` (unchanged); a repeat/variant resolving the same canonical
         # reuses this Media (and gets its url added to the list in the dedup-hit branch below)
         {{:error, :not_found}, _} <-
           {get_by_path(
              if(opts[:update_existing] == :force, do: url_main_key, else: canonical_url)
            ), extra},
         {:ok, media} <-
           insert(
             current_user,
             url_main_key,
             %{id: opts[:id], media_type: media_type, size: 0},
             extra
           ) do
      # |> debug
      if is_function(opts[:post_create_fn], 3) do
        opts[:post_create_fn].(current_user, media, opts)
        |> debug()
      else
        media
      end
    else
      {{:ok, media}, extra} ->
        # dedup-hit (same canonical): also record this source url on the existing Media, so a later
        # lookup by it (another variant of the same article) finds it directly
        media = maybe_append_source_url(media, url)

        if opts[:update_existing] do
          media = from_ok(update(current_user, media, extra))

          if opts[:update_existing] == :force and is_function(opts[:post_create_fn], 3) do
            opts[:post_create_fn].(current_user, media, opts)
            |> debug()
          else
            media
          end
        else
          media
        end

      other ->
        error(other)
        nil
    end
  catch
    e ->
      # workaround for badly-parsed webpages in non-UTF8 encodings
      error(e, "Could not save the URL preview")
      nil
  rescue
    e ->
      error(e, "Could not save the URL preview")
      nil
  end

  # record the source url in metadata["urls"] as a lookup key, unless it's already the primary `path`.
  # the entry is slash-normalized (the list is only a lookup index) so `/post` and `/post/` collapse, while the identity `path` stays exact
  defp maybe_put_source_url(metadata, url, path) when is_binary(url) do
    source = Bonfire.Common.URIs.strip_trailing_slash(url)

    if source == path do
      metadata
    else
      Map.update(metadata, :urls, [source], fn urls -> Enum.uniq([source | List.wrap(urls)]) end)
    end
  end

  defp maybe_put_source_url(metadata, _url, _path), do: metadata

  # on a dedup-hit, add this (slash-normalized) source url to the existing Media's metadata["urls"]
  defp maybe_append_source_url(%Media{} = media, url) when is_binary(url) do
    source = Bonfire.Common.URIs.strip_trailing_slash(url)
    urls = e(media.metadata, "urls", []) |> List.wrap()

    if source == media.path or source in urls do
      media
    else
      case update(nil, media, %{metadata: Map.put(media.metadata || %{}, "urls", [source | urls])}) do
        {:ok, updated} -> updated
        _ -> media
      end
    end
  end

  defp maybe_append_source_url(media, _url), do: media

  @doc """
  Finds a Media by a url, matching either the primary `path` (the canonical) or a source url recorded
  in `metadata["urls"]`. Tracking params are stripped first, to match how the url was stored.

  Lookup order (exact identity first, so a genuinely-distinct page always wins its own anchor and the
  slash fallback only fires when the exact form has no anchor of its own):
    1. `get_by_path(url)` — exact match on the stored canonical `path`
    2. `get_by_path(strip_trailing_slash(url))` — catches a `/post`-canonical from a `/post/` lookup
    3. `get_by_source_url(strip_trailing_slash(url))` — the slash-normalized `metadata["urls"]` index
  """
  def get_by_url(url) when is_binary(url) do
    url = Bonfire.Common.URIs.strip_tracking_params(url)
    stripped = Bonfire.Common.URIs.strip_trailing_slash(url)

    with {:error, _} <- get_by_path(url),
         {:error, _} <- maybe_get_by_stripped_path(stripped, url) do
      get_by_source_url(stripped)
    end
  end

  def get_by_url(_), do: {:error, :not_found}

  # only worth a second path query when the slash-stripped form differs from the exact one
  defp maybe_get_by_stripped_path(stripped, url) when stripped != url, do: get_by_path(stripped)
  defp maybe_get_by_stripped_path(_stripped, _url), do: {:error, :not_found}

  defp get_by_source_url(url) do
    import Ecto.Query

    from(m in Media,
      where: fragment("? -> 'urls' \\? ?", m.metadata, ^url) and is_nil(m.deleted_at),
      limit: 1
    )
    |> repo().one()
    |> case do
      %Media{} = media -> {:ok, media}
      _ -> {:error, :not_found}
    end
  end

  def get_or_add_media_by_uri(current_user, uri, to_boundary \\ nil, to_circles \\ [], opts \\ [])

  def get_or_add_media_by_uri(current_user, uri, to_boundary, to_circles, opts)
      when is_binary(current_user) do
    # by_username/1 resolves a username or id and returns `{:ok, user}`, so match the tuple.
    case Bonfire.Me.Users.by_username(current_user) do
      {:ok, %{} = current_user} ->
        get_or_add_media_by_uri(current_user, uri, to_boundary, to_circles, opts)

      _ ->
        error(l("Saving a media requires a creator"))
    end
  end

  def get_or_add_media_by_uri(%{} = current_user, uri, to_boundary, to_circles, opts) do
    opts =
      opts
      |> maybe_add_post_create_fn(
        current_user,
        to_boundary,
        to_circles
      )

    case maybe_fetch_and_save(current_user, uri, opts) do
      %Media{} = media ->
        {:ok, media}

      {:ok, media} ->
        {:ok, media}

      {:error, reason} ->
        {:error, reason}

      nil ->
        error(uri, l("Could not fetch or save media from URI"))

      other ->
        error(other, "Unexpected return from maybe_fetch_and_save")
        {:error, l("Could not process media URI")}
    end
  end

  def get_or_add_media_by_uri(current_user, uri, to_boundary, to_circles, opts) do
    error(l("Saving a media requires a creator"))
  end

  # Helper to add post_create_fn if to_boundary or to_circles is provided
  defp maybe_add_post_create_fn(opts, current_user, to_boundary, to_circles)
       when is_binary(to_boundary) or (is_list(to_circles) and to_circles != []) do
    Keyword.put(opts, :post_create_fn, fn user, media, _opts ->
      publish_opts =
        []
        |> Keyword.put(:to_circles, to_circles)
        |> maybe_add_boundary(to_boundary)

      publish(user, media, publish_opts)
      |> info("media published")

      # return media instead of post
      media
    end)
  end

  defp maybe_add_post_create_fn(opts, _current_user, _to_boundary, _to_circles), do: opts

  # Helper to add boundary if provided
  def maybe_add_boundary(opts, boundary) when is_binary(boundary) do
    Keyword.put(opts, :boundary, boundary)
  end

  def maybe_add_boundary(opts, _), do: opts

  @doc """
  Replaces the standard `Unfurl.Fetcher.fetch/2` so that AP objects are detected (and reused) in the same request that would otherwise just fetch HTML.

  Falls back to a plain HTTP fetch when the AP path is unavailable — federation disabled, remote isn't an AP server, or the request errored before any HTTP call — otherwise unfurling regular web pages would be impossible on instances with federation off.
  """
  def ap_aware_fetch(url, opts \\ []) do
    case Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_and_create_by_uri(
           url,
           opts ++ [return_html_as_fallback: true, repo: Bonfire.Common.Config.repo()]
         )
         |> debug("fetched using AP within Unfurl") do
      {:ok, %{status: status_code, body: body}} ->
        {:ok, body, status_code}

      {:ok, object} when is_struct(object) ->
        {:ok, object, 200}

      other ->
        debug(other, "AP fetch unavailable, falling back to plain HTTP fetch for unfurl")
        Unfurl.Fetcher.fetch(url, opts)
    end
  end
end
