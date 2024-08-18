defmodule Bonfire.Files.Acts.AttachMedia do
  @moduledoc """
  Saves uploaded files as attachments to the post.

  Act Options:
    * `:changeset` - key in assigns to find changeset, required
    * `:attrs` - epic options key to find the attributes at, default: `:post_attrs`.
    * `:uploads` - epic options key to find the uploaded media objects at, default: `:uploaded_media`.
  """
  use Bonfire.Common.Utils
  alias Bonfire.Epics
  alias Bonfire.Epics.Epic

  # alias Bonfire.Files
  alias Ecto.Changeset
  alias Needle.Changesets
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
        # current_user = Keyword.fetch!(epic.assigns[:options], :current_user)
        attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
        uploads_key = Keyword.get(act.options, :uploads, :uploaded_media)

        uploaded_media =
          e(attrs, uploads_key, []) ++
            e(epic.assigns, uploads_key, []) ++
            Keyword.get(epic.assigns[:options], uploads_key, [])

        case changeset do
          %Changeset{valid?: true} = changeset ->
            smart(epic, act, uploaded_media, "upload media")

            cast(changeset, uploaded_media)
            |> Epic.assign(epic, on, ...)

          %Changeset{valid?: false} = changeset ->
            maybe_debug(epic, act, changeset, "invalid changeset")
            epic

          _other ->
            maybe_debug(epic, act, changeset, "Skipping :#{on} due to changeset")
            epic
        end
    end
  end

  def cast(changeset, uploaded_media) do
    List.wrap(uploaded_media)
    |> Enum.map(fn
      {:error, e} -> raise Bonfire.Fail, invalid_argument: e
      m -> %{media: m}
    end)
    |> Changesets.put_assoc(changeset, :files, ...)

    # |> IO.inspect(label: "cs with media")
  end
end
