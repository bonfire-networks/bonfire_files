defmodule Bonfire.Files.Web.UploadEmojiLive do
  use Bonfire.UI.Common.Web, :stateful_component

  prop scope, :any, default: nil
  prop description, :any, default: nil

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)

    emoji =
      case socket.assigns[:scope] |> debug("scooope") do
        :instance ->
          Bonfire.Common.Config.get(:custom_emoji, nil)

        _ ->
          Bonfire.Common.Settings.get(:custom_emoji, nil,
            current_user: current_user(socket.assigns)
          )
      end

    {:ok,
     socket
     |> assign(
       trigger_submit: false,
       uploaded_files: [],
       existing_emoji:
         emoji
         |> info("emlist")
     )
     |> allow_upload(:emoji,
       accept:
         Config.get_ext(
           :bonfire_files,
           [Bonfire.Files.EmojiUploader, :allowed_media_extensions],
           ~w(.jpg .jpeg .png .gif .svg .apng)
         ),
       # TODO: make extensions configurable
       max_file_size: Bonfire.Files.EmojiUploader.max_file_size(),
       max_entries: 1,
       auto_upload: true
       #  progress: &handle_progress/3
     )}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload", %{"label" => label, "shortcode" => shortcode} = params, socket)
      when is_binary(label) and label != "" and is_binary(shortcode) and shortcode != "" do
    current_user = current_user(socket)
    scope = e(socket.assigns, :scope, nil)
    shortcode = ":#{String.trim(shortcode, ":")}:"

    with [%{path: url} = media] <-
           live_upload_files(
             Bonfire.Files.EmojiUploader,
             :emoji,
             scope || current_user,
             %{
               media_type: "emoji",
               label: label,
               shortcode: shortcode
             },
             socket
           ),
         meta = %{label: label, url: url},
         {:ok, settings} <-
           Bonfire.Common.Settings.put(
             [:custom_emoji, shortcode],
             meta,
             scope: scope,
             current_user: current_user
           )
           |> debug("added to settings") do
      {
        :noreply,
        socket
        # TODO: send to persistentLive context to be available in composer
        |> maybe_assign_context(settings)
        |> assign(
          existing_emoji:
            Map.merge(
              %{shortcode => meta},
              (socket.assigns[:existing_emoji] || []) |> Enum.into(%{})
            )
        )
        |> assign_flash(:info, "Emoji added :-)")
        # |> update(:uploaded_files, &(&1 ++ uploaded_files))
      }
    else
      e ->
        warn(e)

        {
          :noreply,
          socket
          |> assign_error("Please check all inputs and try again.")
        }
    end
  end

  def handle_event("upload", params, socket) do
    warn(params)

    {
      :noreply,
      socket
      |> assign_error("Please check all inputs and try again.")
    }
  end

  # def handle_progress(
  #       type,
  #       entry,
  #       socket
  #     ),
  #     do:
  #       Bonfire.UI.Common.LiveHandlers.handle_progress(
  #         type,
  #         entry,
  #         socket,
  #         __MODULE__,
  #         Bonfire.Files.LiveHandler
  #       )
end
