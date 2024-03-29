defmodule Bonfire.Files.Web.UploadIconLive do
  use Bonfire.UI.Common.Web, :stateful_component

  prop src, :string, default: nil
  prop object, :any, default: nil
  # prop uploads, :any, default: nil
  prop boundary_verb, :atom, default: :edit
  prop set_field, :any, default: nil
  prop set_fn, :any, default: nil
  prop label, :string, default: nil
  prop wrapper_class, :css_class, default: ["flex items-center gap-4"]
  prop label_on_hover, :boolean, default: true

  prop container_class, :css_class,
    default: [
      "relative flex-shrink-0 block w-24 h-24 overflow-hidden rounded-md ring-4 ring-base-300"
    ]

  prop label_class, :css_class,
    default: [
      "absolute inset-0 flex items-center justify-center w-full h-full text-sm font-medium text-center text-white transition duration-150 ease-in-out opacity-0 cursor-pointer hover:bg-black bg-base-100 bg-opacity-40 hover:opacity-60 focus-within:opacity-60"
    ]

  prop class, :css_class, default: nil
  prop bg_class, :css_class, default: ["rounded-md bg-base-100 h-full"]
  prop opts, :any, default: %{"data-id" => "preview_icon"}

  defp upload_error_to_string(:too_large), do: "The file is too large"

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(
       trigger_submit: false,
       uploaded_files: []
     )
     |> assign(assigns)
     |> allow_upload(:icon,
       accept:
         Config.get_ext(
           :bonfire_files,
           [Bonfire.Files.IconUploader, :allowed_media_extensions],
           ~w(.jpg .png)
         ),
       # make extensions & size configurable
       max_file_size: Bonfire.Files.IconUploader.max_file_size(),
       max_entries: 1,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  def handle_progress(
        type,
        entry,
        socket
      ),
      do:
        Bonfire.UI.Common.LiveHandlers.handle_progress(
          type,
          entry,
          socket,
          __MODULE__,
          Bonfire.Files.LiveHandler
        )
end
