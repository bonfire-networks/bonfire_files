defmodule Bonfire.Files.LiveHandler do
  use Bonfire.UI.Common.Web, :live_handler

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_progress(:banner = type, entry, socket) do
    do_handle_progress(Bonfire.Files.BannerUploader, type, entry, socket)
  end

  def handle_progress(:icon = type, entry, socket) do
    do_handle_progress(Bonfire.Files.IconUploader, type, entry, socket)
  end

  def handle_progress(:document = type, entry, socket) do
    do_handle_progress(Bonfire.Files.DocumentUploader, type, entry, socket)
  end

  def handle_progress(type, entry, socket) do
    do_handle_progress(Bonfire.Files.ImageUploader, type, entry, socket)
  end

  defp do_handle_progress(mod, type, entry, socket) do
    user = current_user_required!(socket)
    object = e(assigns(socket), :object, nil)
    boundary_verb = e(assigns(socket), :boundary_verb, nil) || :edit
    set_field = e(assigns(socket), :set_field, nil)
    set_fn = e(assigns(socket), :set_fn, &set_fallback/5)

    if user &&
         (id(user) == id(object) or
            (object && is_atom(object) && object == :pandora_list) or
            maybe_apply(Bonfire.Boundaries, :can?, [user, boundary_verb, object])) &&
         entry.done? do
      maybe_consume_uploaded_entry(socket, entry, fn %{path: path} = metadata ->
        # debug(metadata, "icon consume_uploaded_entry meta")
        # `consume_uploaded_entry/3` requires an `{:ok, _} | {:postpone, _}` return, so wrap the result (success *or* failure) and unwrap it below, otherwise a failed upload trips LiveView's contract warning instead of reaching our error handling
        {:ok,
         mod.upload(user, path, %{
           client_name: entry.client_name,
           metadata: metadata[entry.ref]
         })}

        # |> debug("uploaded")
      end)
      |> case do
        {:ok, %{} = uploaded_media} ->
          # debug(uploaded_media)
          set_fn.(type, object || user, uploaded_media, set_field, socket)

        %{} = uploaded_media ->
          set_fn.(type, object || user, uploaded_media, set_field, socket)

        {:error, %Bonfire.Fail{message: message}} ->
          {:noreply, assign_flash(socket, :error, message)}

        other ->
          # anything else means the upload did not produce media, eg. a storage rejection turned into `{:error, %Ecto.Changeset{}}` by `Attacher.attach/3`
          {:noreply, assign_flash(socket, :error, Bonfire.Common.Errors.error_msg(other))}
      end
    else
      debug("Skip uploading")
      {:noreply, socket}
    end
  end

  def set_fallback(_, _, _, _, socket) do
    {:noreply,
     socket
     |> assign_error("Did not know what to do with the upload because no `set_fn` was provided.")}
  end
end
