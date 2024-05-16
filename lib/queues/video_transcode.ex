defmodule Bonfire.Files.Queues.VideoTranscode do
  @moduledoc """
  WIP https://github.com/bonfire-networks/bonfire-app/issues/920
  """
  # import Plug.Conn
  import Phoenix.ConnTest
  use Untangle
  alias Bonfire.Common.Config

  use Oban.Worker,
    queue: :video_transcode,
    max_attempts: 1

  @impl Oban.Worker
  def perform(job) do
    transcode(job)
    :ok
  end

  def transcode(job) do
    IO.inspect(job)
  end
end
