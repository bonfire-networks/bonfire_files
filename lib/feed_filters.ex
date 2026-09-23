defmodule Bonfire.Files.FeedFilters do
  @moduledoc """
  Narrows a feed by the media its activities carry: `media_types` keeps what has any of these types, `exclude_media_types` leaves it out, and `"*"` means any media at all.

  Lives here rather than in the feed loader because media are this extension's: its schema, its attachments, and the join that reaches them. `bonfire_social` holds this extension only as an optional dependency, so a feed query naming `Bonfire.Files.Media` directly was a compile-time reach into something that may not be installed. The keys are declared as fields on `Bonfire.Social.FeedFilters` from this extension's config, and this module applies them; `Bonfire.Common.FeedFilterModule` explains why the two halves live where they do.

  A media type matches by prefix, so `image` covers `image/png`, and `link` stands for the kinds of thing a link preview is stored as.
  """
  use Bonfire.Common.Utils, only: []
  use Bonfire.Common.Repo
  import Untangle

  @behaviour Bonfire.Common.FeedFilterModule

  @impl true
  def feed_filter_module, do: __MODULE__

  @impl true
  def maybe_filter(query, filter, opts \\ [])

  def maybe_filter(query, {:media_types, types}, opts) when is_list(types) and types != [] do
    per_media? = :per_media in List.wrap(opts[:preload])

    case prepare_filter_media_type(types) do
      :all ->
        filter_has_media(query)

      [first | rest] ->
        # one WHERE rather than one per type, as the ORs of a single condition
        media_type_filter =
          Enum.reduce(
            rest,
            dynamic([media: media], ilike(media.media_type, ^"#{first}%")),
            fn type, dynamic_query ->
              dynamic([media: media], ^dynamic_query or ilike(media.media_type, ^"#{type}%"))
            end
          )

        query
        |> maybe_proload_media(per_media? || :left)
        |> where(^media_type_filter)

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

      [first | rest] ->
        # what carries no media at all is kept, which is the `is_nil(media.id)` half
        media_type_filter =
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

        query
        |> maybe_proload_media(per_media? || :left)
        |> where(^media_type_filter)

      other ->
        warn(other, "Unrecognised media type")
        query
    end
  end

  def maybe_filter(query, _filter, _opts), do: query

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

  defp filter_has_media(query) do
    query
    |> maybe_proload_media(:has_one)
    |> where([media: media], not is_nil(media.media_type))
  end

  defp prepare_filter_media_type(types) do
    cond do
      "*" in types or :* in types -> :all
      :link in types or "link" in types -> ["link", "article", "profile", "website"] ++ types
      true -> types
    end
  end
end
