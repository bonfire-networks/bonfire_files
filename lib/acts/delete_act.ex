defmodule Bonfire.Files.Acts.Delete do
  @moduledoc """
  An act that deletes media
  """
  import Bonfire.Epics
  use Arrows
  require Logger

  # alias Bonfire.Epics
  # alias Bonfire.Epics.Act
  alias Bonfire.Epics.Epic
  alias Bonfire.Common.Utils
  alias Bonfire.Common.Enums
  alias Ecto.Changeset

  # see module documentation
  @doc false
  def run(epic, act) do
    on = Keyword.get(act.options, :on, :delete_media)
    media = epic.assigns[on] || Keyword.get(epic.assigns[:options], on)
    action = Keyword.get(epic.assigns[:options], :action)

    if epic.errors != [] do
      maybe_debug(
        epic,
        act,
        length(epic.errors),
        "Delete media: Skipping due to epic errors"
      )

      epic
    else
      case action do
        :delete ->
          maybe_debug(epic, act, media, "Delete media")

          # the object being deleted still holds its own `Files` rows here (its pointer is only soft-deleted), so they don't count as someone else's
          deleted_object = Keyword.get(epic.assigns[:options], :object)

          media
          |> List.wrap()
          |> Enums.filter_empty([])
          |> Enum.map(fn m ->
            if Bonfire.Files.Media.attached_elsewhere?(m, deleted_object) do
              maybe_debug(
                epic,
                act,
                Enums.id(m),
                "Keeping media still attached to another object"
              )
            else
              Bonfire.Files.Media.hard_delete(m)
            end
          end)

          # 

          epic

        action ->
          maybe_debug(epic, act, action, "Delete media: Skipping due to unknown action")
          epic
      end
    end
  end
end
