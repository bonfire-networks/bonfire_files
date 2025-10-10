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

  alias Bonfire.Files
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
        current_user = Bonfire.Common.Utils.current_user(epic.assigns[:options])
        # attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        # attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
        urls_key = Keyword.get(act.options, :urls, :urls)
        media_key = Keyword.get(act.options, :medias, :uploaded_media)
        quotes_key = Keyword.get(act.options, :quotes, :quotes)
        text_key = Keyword.get(act.options, :text, :text)

        case changeset do
          %Changeset{valid?: true} = changeset ->
            # smart(epic, act, changeset, "valid changeset")

            urls =
              (epic.assigns[:options][urls_key] || Map.get(epic.assigns, urls_key, []))
              |> debug("initial urls")
              |> smart(epic, act, ..., "URLs")

            urls_media =
              Bonfire.Files.Media.maybe_fetch_and_save(current_user, urls)
              |> debug("urls media")

            #  support also detecting non-URL strings in the text content
            # TODO: avoid a custom hook here and make generic
            text_media =
              if module = maybe_module(Bonfire.OpenScience.APIs) do
                (Map.get(epic.assigns, text_key) || epic.assigns[:options][text_key] || "")
                |> String.split()
                |> Enum.reject(&(&1 in urls or !module.is_pub_id_or_uri_match?(&1)))
                # |> IO.inspect()
                |> Bonfire.Files.Media.maybe_fetch_and_save(current_user, ...,
                  fetch_fn: fn url, opts -> module.fetch(url, opts) end
                )
              else
                []
              end

            (text_media ++ urls_media)
            |> Enums.filter_empty([])
            |> Enum.split_with(&is_struct(&1, Bonfire.Files.Media))
            |> debug("split media and quotes")
            |> case do
              {media_objects, quote_objects} ->
                epic
                |> Epic.assign(media_key, media_objects)
                |> Epic.assign(quotes_key, quote_objects)
            end

          %Changeset{valid?: false} = changeset ->
            maybe_debug(epic, act, changeset, "invalid changeset")
            epic

          _other ->
            maybe_debug(epic, act, changeset, "Skipping :#{on} due to changeset")
            epic
        end
    end
  end

  # defp assign_medias(epic, act, _on, meta_key, data) do
  #   smart(epic, act, data, "found #{meta_key}")
  #   Epic.assign(epic, meta_key, data)
  # end
end
