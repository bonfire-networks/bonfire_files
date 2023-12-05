defmodule Bonfire.Files.Versions do
  defstruct [:default, :thumbnail]
end

defimpl Capsule.Upload, for: Bonfire.Files.Versions do
  use Arrows
  import Untangle

  def path(versions) do
    path = get_path(versions)

    case File.exists?(path) do
      false ->
        error(path, "Source file does not exist")
        nil

      true ->
        path
    end
  end

  defp get_path(versions, version \\ :default) do
    (Map.get(versions, version) || %{})
    |> Map.get(:path) || get_path(versions, :thumbnail)
  end

  def contents(versions) do
    case path(versions)
         ~> File.read() do
      {:error, reason} -> {:error, "Could not read file: #{reason}"}
      success_tuple -> success_tuple
    end
  end

  def name(versions, version \\ :default),
    do:
      (Map.get(versions, version) || %{})
      |> Map.get(:filename) || name(versions, :thumbnail)
end
