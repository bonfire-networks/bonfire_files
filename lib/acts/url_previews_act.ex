defmodule Bonfire.Files.Acts.URLPreviews do
  @moduledoc """
  Fetch and save metadata of URLs

  Act Options:
    * `:changeset` - key in assigns to find changeset, required
    * `:attrs` - epic options key to find the attributes at, default: `:post_attrs`.
    * `:uploads` - epic options key to find the uploaded media objects at, default: `:urls`.
  """
  use Bonfire.Common.Utils
  alias Bonfire.Epics
  alias Bonfire.Epics.Epic

  # alias Bonfire.Files
  alias Ecto.Changeset
  # alias Needle.Changesets
  # import Bonfire.Common.Config, only: [repo: 0]
  import Epics
  # import Untangle, only: [error: 2, warn: 1]

  def run(epic, act) do
    cond do
      epic.errors != [] ->
        Epics.smart(epic, act, epic.errors, "Skipping due to epic errors")
        epic

      true ->
        on = Keyword.fetch!(act.options, :on)
        changeset = epic.assigns[on]
        current_user = Keyword.fetch!(epic.assigns[:options], :current_user)
        # attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        # attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
        urls_key = Keyword.get(act.options, :urls, :urls)
        media_key = Keyword.get(act.options, :medias, :uploaded_media)
        text_key = Keyword.get(act.options, :text, :text)

        case changeset do
          %Changeset{valid?: true} = changeset ->
            # smart(epic, act, changeset, "valid changeset")

            urls =
              (epic.assigns[:options][urls_key] || Map.get(epic.assigns, urls_key, []))
              |> smart(epic, act, ..., "URLs")

            urls_media = maybe_fetch_and_save(current_user, urls)

            text_media =
              if module = maybe_module(Bonfire.OpenScience.APIs) do
                (Map.get(epic.assigns, text_key) || epic.assigns[:options][text_key] || "")
                |> String.split()
                |> Enum.reject(&(&1 in urls or !module.is_pub_id_or_uri_match?(&1)))
                # |> IO.inspect()
                |> maybe_fetch_and_save(current_user, ...,
                  fetch_fn: fn url, opts -> module.fetch(url, opts) end
                )
                |> Enums.filter_empty([])
              else
                []
              end

            (text_media ++ urls_media)
            # |> IO.inspect(label: "all media")
            |> smart(epic, act, ..., "metadata")
            |> Epic.assign(epic, media_key, ...)

          %Changeset{valid?: false} = changeset ->
            maybe_debug(epic, act, changeset, "invalid changeset")
            epic

          _other ->
            maybe_debug(epic, act, changeset, "Skipping :#{on} due to changeset")
            epic
        end
    end
  end

  def maybe_fetch_and_save(current_user, url, opts \\ [])

  def maybe_fetch_and_save(current_user, urls, opts) when is_list(urls) do
    urls
    |> Enum.map(&maybe_fetch_and_save(current_user, &1, opts))
  end

  def maybe_fetch_and_save(current_user, url, opts) when is_binary(url) do
    with {:error, :not_found} <- Bonfire.Files.Media.get_by_path(url) do
      do_maybe_fetch_and_save(current_user, url, opts)
    else
      {:ok, media} ->
        # already exists
        if opts[:update_existing] == :force do
          do_maybe_fetch_and_save(current_user, url, opts)
        else
          media
        end

      _ ->
        nil
    end
  end

  defp do_maybe_fetch_and_save(current_user, url, opts) do
    with {:ok, meta} <-
           if(opts[:fetch_fn], do: opts[:fetch_fn].(url, opts), else: Unfurl.unfurl(url, opts)),
         # note: canonical url is only set if different from original url, so we only check each unique url once
         canonical_url <- Map.get(meta, :canonical_url),
         media_type <-
           if(opts[:type_fn],
             do: opts[:type_fn].(meta),
             else:
               e(meta, :facebook, "type", nil) || e(meta, :oembed, "type", nil) ||
                 e(meta, :wikidata, "itemType", nil) || "link"
           ),
         extra <- %{
           media_type: media_type,
           metadata:
             Enum.into(
               opts[:extra] || %{},
               meta
               |> Map.drop([:canonical_url])
               |> Enums.filter_empty(nil)
             )
         },
         {{:error, :not_found}, _} <-
           {Bonfire.Files.Media.get_by_path(
              if opts[:update_existing] == :force, do: canonical_url || url, else: canonical_url
            ), extra},
         {:ok, media} <-
           Bonfire.Files.Media.insert(
             current_user,
             canonical_url || url,
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
        # already exists with same canonical_url
        if opts[:update_existing] do
          media = ok_unwrap(Bonfire.Files.Media.update(current_user, media, extra))

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
        # error(other)
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

  # defp assign_medias(epic, act, _on, meta_key, data) do
  #   smart(epic, act, data, "found #{meta_key}")
  #   Epic.assign(epic, meta_key, data)
  # end
end
