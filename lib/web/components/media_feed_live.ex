defmodule Bonfire.UI.Files.Web.MediaFeedLive do
  use Bonfire.UI.Common.Web, :surface_live_view

  declare_nav_link(l("Media"),
    page: "media",
    href: "/media",
    icon: "carbon:image"
    # icon: "carbon:document"
  )

  on_mount {LivePlugs, [Bonfire.UI.Me.LivePlugs.LoadCurrentUser]}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       feed_id: :media,
       page_title: "Media"
     )}
  end

  # def handle_params(%{"tab" => tab} = _params, _url, socket) do
  #   {:noreply,
  #    assign(socket,
  #      selected_tab: tab
  #    )}
  # end

  # def handle_params(%{} = _params, _url, socket) do
  #   {:noreply,
  #    assign(socket,
  #      current_user: Fake.user_live()
  #    )}
  # end
end
