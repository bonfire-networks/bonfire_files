defmodule Bonfire.Files.FeedFilters do
  @moduledoc """
  Narrows a feed by the media its activities carry: `media_types` keeps what has any of these types, `exclude_media_types` leaves it out, and `"*"` means any media at all.

  Lives here rather than in the feed loader because media are this extension's: its schema, its attachments, and the join that reaches them. `bonfire_social` holds this extension only as an optional dependency, so a feed query naming `Bonfire.Files.Media` directly was a compile-time reach into something that may not be installed. The keys are declared as fields on `Bonfire.Social.FeedFilters` from this extension's config, and this module applies them; `Bonfire.Common.FeedFilterModule` explains why the two halves live where they do.

  A media type matches by prefix, so `image` covers `image/png`, and `link` stands for the kinds of thing a link preview is stored as. `"attachment"` means media a client shows as an attachment: any media that is not a link preview, by its type or by an HTML `content_type` (Mastodon's `only_media`).
  """
  use Bonfire.Common.Utils, only: []
  use Bonfire.Common.Repo
  import Untangle

  @behaviour Bonfire.Common.FeedFilterModule

  # a link preview's kind is decided once, when it's saved (`Bonfire.Files.link_type/2`: `link`, `research`, a kind like `event` or `book`, `video/embed`, `audio/embed`), so these filters only match stored types. `Bonfire.Files.link_preview_types/0` lists every type a preview without a player is stored with (also what Mastodon clients get as a `card`, not an attachment, `Mappers.PreviewCard.link?/1`), and the Open Graph types previews were stored with before, for rows not yet retyped; wider than `link` below
  # TODO: bring back the images, videos and audio feed presets (commented out in bonfire_social's runtime config), showing files and embeds together, and a documents one
  @link_preview_content_types ["text/html", "application/xhtml+xml"]

  @impl true
  def feed_filter_module, do: __MODULE__

  @impl true
  def maybe_filter(query, filter, opts \\ [])

  def maybe_filter(query, {:media_types, types}, opts) when is_list(types) and types != [] do
    per_media? = :per_media in List.wrap(opts[:preload])

    case prepare_filter_media_type(types) do
      :all ->
        query
        |> maybe_proload_media(:has_one)
        |> where(^media_condition({:media_types, types}))

      :attachments ->
        query
        |> maybe_proload_media(:has_one)
        |> where(^media_condition({:media_types, types}))

      [_ | _] ->
        query
        |> maybe_proload_media(per_media? || :left)
        |> where(^media_condition({:media_types, types}))

      other ->
        warn(other, "Unrecognised media type")
        query
    end
  end

  def maybe_filter(query, {:exclude_media_types, types}, opts)
      when is_list(types) and types != [] do
    per_media? = :per_media in List.wrap(opts[:preload])

    case prepare_filter_media_type(types) do
      # what carries no media at all: a left join, since an inner one removes exactly the rows this asks for, and a missing media row rather than a missing type
      :all ->
        query
        |> maybe_proload_media(per_media? || :left)
        |> where([media: media], is_nil(media.id))

      [_ | _] ->
        query
        |> maybe_proload_media(per_media? || :left)
        |> where(^media_condition({:exclude_media_types, types}))

      other ->
        warn(other, "Unrecognised media type")
        query
    end
  end

  # media with a file of ours (an upload, or an imported file with its storage): a link preview or an embed is only a URL, with no `file`
  def maybe_filter(query, {:media_has_file, true}, opts) do
    per_media? = :per_media in List.wrap(opts[:preload])

    query
    |> maybe_proload_media(per_media? || :left)
    |> where([media: media], not is_nil(media.file))
  end

  def maybe_filter(query, _filter, _opts), do: query

  @doc """
  The condition `media_types` or `exclude_media_types` puts on the media an activity carries, as a `dynamic` on a `media` binding, or `nil` when the types are not recognised.

  Usable on the `media` binding of a feed query, or of any query rooted at `Bonfire.Files.Media` with `as: :media`, such as one picking the newest media of a type.
  """
  def media_condition({:media_types, types}) when is_list(types) and types != [] do
    case prepare_filter_media_type(types) do
      :all ->
        dynamic([media: media], not is_nil(media.media_type))

      :attachments ->
        attachment_condition()

      [first | rest] ->
        # one condition rather than one per type, as the ORs of a single condition
        media_type_filter =
          Enum.reduce(
            rest,
            dynamic([media: media], ilike(media.media_type, ^"#{first}%")),
            fn type, dynamic_query ->
              dynamic([media: media], ^dynamic_query or ilike(media.media_type, ^"#{type}%"))
            end
          )

        if link_previews_excluded?(types),
          do: dynamic(^media_type_filter and ^document_condition()),
          else: media_type_filter

      _ ->
        nil
    end
  end

  def media_condition({:exclude_media_types, types}) when is_list(types) and types != [] do
    case prepare_filter_media_type(types) do
      # what carries no media at all: a missing media row rather than a missing type
      :all ->
        dynamic([media: media], is_nil(media.id))

      [first | rest] ->
        # what carries no media at all is kept, which is the `is_nil(media.id)` half
        Enum.reduce(
          rest,
          dynamic(
            [media: media],
            is_nil(media.id) or not ilike(media.media_type, ^"#{first}%")
          ),
          fn type, dynamic_query ->
            dynamic([media: media], ^dynamic_query and not ilike(media.media_type, ^"#{type}%"))
          end
        )

      _ ->
        nil
    end
  end

  def media_condition(_), do: nil

  @doc "Joins the media an activity carries, directly or through its attachments, and loads them on the activity."
  def maybe_proload_media(query, per_media_or_join) do
    cond do
      per_media_or_join in [true, :has_one] ->
        projoin(query, :inner, activity: [:media])

      per_media_or_join == :inner ->
        query
        |> join_media(:inner)
        |> proload(:inner, activity: [:media])

      true ->
        query
        |> join_media(:left)
        |> proload(:left, activity: [:media])
    end || query
  end

  @doc """
  Joins the media an activity carries, as the `media` binding: those attached to its object (through `files`) and an activity whose object is itself a media.

  `:inner` keeps only activities with some; anything else keeps every activity, with `media` null where there is none.
  """
  def join_media(query, :inner) do
    query
    |> reusable_join(:left, [activity: activity], files in assoc(activity, :files), as: :files)
    |> reusable_join(
      :inner,
      [activity: activity, files: files],
      media in Bonfire.Files.Media,
      as: :media,
      on: files.media_id == media.id or activity.id == media.id
    )
  end

  def join_media(query, _) do
    query
    |> reusable_join(:left, [activity: activity], files in assoc(activity, :files), as: :files)
    |> reusable_join(
      :left,
      [activity: activity, files: files],
      media in Bonfire.Files.Media,
      as: :media,
      on: files.media_id == media.id or activity.id == media.id
    )
  end

  # as any media, without link previews; one stored under another type is still caught by its HTML `content_type`
  defp attachment_condition do
    dynamic(
      [media: media],
      not is_nil(media.media_type) and
        media.media_type not in ^Bonfire.Files.link_preview_types() and
        not ilike(media.media_type, "%/embed") and not ilike(media.media_type, "text/html%") and
        fragment(
          "coalesce(?->>'content_type', '') <> ALL(?)",
          media.metadata,
          type(^@link_preview_content_types, {:array, :string})
        )
    )
  end

  # documents match by the `application` and `text` prefixes, which a link preview stored as HTML also has: asked for documents (and not links), link previews are left out as `attachment_condition/0` leaves them out
  defp link_previews_excluded?(types) do
    Enum.any?(types, &(&1 in [:document, "document"])) and
      not Enum.any?(types, &(&1 in [:link, "link"]))
  end

  defp document_condition do
    dynamic(
      [media: media],
      # a document embed is a link to a document on a host that shows it (its page is HTML, so it'd be left out below)
      ilike(media.media_type, "document/%") or
        (media.media_type not in ^Bonfire.Files.link_preview_types() and
           media.media_type not in ^@link_preview_content_types and
           not ilike(media.media_type, "text/html%") and
           not ilike(media.media_type, "%mpegurl") and
           fragment(
             "coalesce(?->>'content_type', '') <> ALL(?)",
             media.metadata,
             type(^@link_preview_content_types, {:array, :string})
           ))
    )
  end

  defp prepare_filter_media_type(types) do
    cond do
      "*" in types or :* in types -> :all
      "attachment" in types or :attachment in types -> :attachments
      true -> Enum.flat_map(types, &media_type_prefixes/1)
    end
  end

  # a type a person picks, as the prefixes of the media types it covers. A link preview is stored as `link`, `research`, `video/embed` or `audio/embed` (`Bonfire.Files.link_type/2`), or as `text/html` when an incoming `Link` says so
  # TODO: links to a page of a kind (`event`, `book`, `profile`, `recipe`, `place`, `product`) aren't matched here, so they're left out of the links feed and trending links: decide whether `link` covers every kind (`Bonfire.Files.link_preview_types/0`), which also brings in old rows typed `book` or `profile` from Open Graph
  defp media_type_prefixes(type) when type in [:link, "link"], do: ["link", "text/html"]

  # an HLS stream is a video, though its MIME type is an `application` one
  defp media_type_prefixes(type) when type in [:video, "video"],
    do: ["video", "application/x-mpegurl", "application/vnd.apple.mpegurl"]

  # a document is any file that isn't an image, video or audio: a PDF, a text file, etc.
  defp media_type_prefixes(type) when type in [:document, "document"],
    do: ["application", "text", "document"]

  defp media_type_prefixes(type), do: [type]
end
