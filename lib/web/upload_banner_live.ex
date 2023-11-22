defmodule Bonfire.Files.Web.UploadBannerLive do
  use Bonfire.UI.Common.Web, :stateful_component

  prop src, :string, default: nil
  prop object, :any, default: nil
  prop boundary_verb, :atom, default: :edit
  prop set_field, :any, default: nil
  prop set_fn, :any, default: nil
  # prop uploads, :any, default: nil

  prop container_class, :css_class,
    default: ["relative flex justify-center px-6 py-10 bg-center bg-cover h-[200px]"]

  prop label_class, :css_class,
    default: [
      "absolute inset-0 flex flex-col items-center justify-center w-full h-full text-sm font-medium text-white rounded-lg cursor-pointer bg-base-100 bg-opacity-40 opacity-60"
    ]

  # prop label_class, :css_class, default: ["absolute inset-0 flex flex-col items-center justify-center w-full h-full text-sm font-medium text-white transition duration-150 ease-in-out rounded-lg opacity-0 cursor-pointer bg-base-100 bg-opacity-40 hover:opacity-60 focus-within:opacity-60"]

  defp upload_error_to_string(:too_large), do: "The file is too large"

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(
       trigger_submit: false,
       uploaded_files: []
     )
     |> assign(assigns)
     |> allow_upload(:banner,
       accept:
         Config.get_ext(
           :bonfire_files,
           [Bonfire.Files.BannerUploader, :allowed_media_extensions],
           ~w(.jpg .png)
         ),
       # make extensions & size configurable
       max_file_size:
         Bonfire.Common.Config.get([Bonfire.Files, :max_user_images_file_size], 5) * 1_000_000,
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

  def handle_event(
        action,
        attrs,
        socket
      ),
      do:
        Bonfire.UI.Common.LiveHandlers.handle_event(
          action,
          attrs,
          socket,
          __MODULE__
          # &do_handle_event/3
        )
end
