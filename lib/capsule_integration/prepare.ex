defmodule Bonfire.Files.Prepare do
  # based on `Waffle.Actions.Store`
  # TODO: remove dependency on Waffle
  alias Waffle.Definition.Versioning
  alias Waffle.Processor
  alias Waffle.File

  use Arrows
  alias Bonfire.Common.Enums

  defmacro __using__(_) do
    quote do
      def prepare(args), do: Bonfire.Files.Prepare.prepare(__MODULE__, args)
    end
  end

  def prepare(definition, {file, scope}) when is_binary(file) or is_map(file) do
    do_prepare(definition, {File.new(file, definition), scope})
  end

  def prepare(definition, filepath) when is_binary(filepath) or is_map(filepath) do
    prepare(definition, {filepath, nil})
  end

  #
  # Private
  #

  defp do_prepare(_definition, {error = {:error, _msg}, _scope}), do: error

  defp do_prepare(definition, {%File{} = file, scope}) do
    case definition.validate({file, scope}) do
      result when result == true or result == :ok ->
        versions = put_versions(definition, {file, scope})
        cleanup!(file)
        versions

      {:error, message} ->
        {:error, message}

      _ ->
        {:error, :invalid_file}
    end
  end

  defp put_versions(definition, {file, scope}) do
    if definition.async do
      definition.__versions
      |> Enum.map(fn r -> async_process_version(definition, r, {file, scope}) end)
      |> Enum.map(fn task -> Task.await(task, version_timeout()) end)
      |> ensure_all_success
      |> Enum.map(fn {v, r} -> async_put_version(definition, v, {r, scope}) end)
      |> Enum.map(fn task -> Task.await(task, version_timeout()) end)
      |> handle_responses()
    else
      definition.__versions
      |> Enum.map(fn version -> process_version(definition, version, {file, scope}) end)
      |> ensure_all_success
      |> Enum.map(fn {version, result} -> put_version(definition, version, {result, scope}) end)
      |> handle_responses()
    end
  end

  defp ensure_all_success(responses) do
    errors = Enum.filter(responses, fn {_version, resp} -> elem(resp, 0) == :error end)
    if Enum.empty?(errors), do: responses, else: errors
  end

  defp handle_responses(ok: file) do
    {:ok,
     file
     |> struct(Bonfire.Files.Versions, ...)}
  end

  defp handle_responses(responses) do
    errors = Enums.unwrap_tuples(responses, :error)

    if is_nil(errors) do
      {:ok,
       Enums.unwrap_tuples(responses, :ok)
       |> Enums.deep_merge_reduce()
       |> struct(Bonfire.Files.Versions, ...)}
    else
      {:error, errors}
    end
  end

  def unwrap_tuples(responses, key) do
    # TODO: optimise
    Enum.filter(responses, fn resp -> elem(resp, 0) == key end)
    |> Enum.map(fn v -> elem(v, 1) end)
    |> Enum.uniq()
    |> Enums.filter_empty(nil)
  end

  defp version_timeout do
    Application.get_env(:waffle, :version_timeout) || 15_000
  end

  defp async_process_version(definition, version, {file, scope}) do
    Task.async(fn ->
      process_version(definition, version, {file, scope})
    end)
  end

  defp async_put_version(definition, version, {result, scope}) do
    Task.async(fn ->
      put_version(definition, version, {result, scope})
    end)
  end

  defp process_version(definition, version, {file, scope}) do
    {version, Processor.process(definition, version, {file, scope})}
  end

  defp put_version(definition, version, {result, scope}) do
    case result do
      {:error, error} ->
        {:error, error}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, file} ->
        file_name = Versioning.resolve_file_name(definition, version, {file, scope})
        file = %File{file | file_name: file_name}

        # result    = definition.__storage.put(definition, version, {file, scope})
        if binary = file.binary do
          destination_path = definition.url({file, scope}, version) |> String.trim_leading("/")
          File.write!(destination_path, binary)
          %File{file | path: destination_path}
        else
          file
        end

        case definition.transform(version, {file, scope}) do
          :noaction ->
            # We don't have to cleanup after `:noaction` transformations
            # because final `cleanup!` will remove the original temporary file.
            nil

          _ ->
            nil
            # cleanup!(file)
        end

        # result
        {:ok,
         %{
           version => %{
             path: file.path,
             filename: file_name
           }
         }}
    end
  end

  defp cleanup!(file) do
    # If we were working with binary data or a remote file, a tempfile was
    # created that we need to clean up.
    if file.is_tempfile? do
      Elixir.File.rm!(file.path)
    end
  end
end
