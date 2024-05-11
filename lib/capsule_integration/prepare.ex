defmodule Bonfire.Files.Prepare do
  # based on `Waffle.Actions.Store`
  # TODO: remove dependency on Waffle
  alias Waffle.Definition.Versioning
  alias Waffle.Processor

  use Arrows
  import Untangle
  alias Bonfire.Common.Utils
  alias Bonfire.Common.Enums

  defmacro __using__(_) do
    quote do
      def prepare(args), do: Bonfire.Files.Prepare.prepare(__MODULE__, args)
    end
  end

  def prepare(definition, {file, scope}) when is_binary(file) or is_map(file) do
    do_prepare(definition, {Waffle.File.new(file, definition), scope})
  end

  def prepare(definition, filepath) when is_binary(filepath) or is_map(filepath) do
    prepare(definition, {filepath, nil})
  end

  #
  # Private
  #

  defp do_prepare(_definition, {error = {:error, _msg}, _scope}), do: error

  defp do_prepare(definition, {%Waffle.File{} = file, scope}) do
    case definition.validate({file, scope}) do
      result when result == true or result == :ok ->
        versions = put_versions(definition, {file, scope})
        cleanup!(file)
        versions

      {:error, message} ->
        error(message)

      _ ->
        error(:invalid_file)
    end
  end

  defp put_versions(definition, {file, scope}) do
    process_timeout = version_timeout(definition)

    if definition.async do
      definition.__versions
      # |> IO.inspect()
      |> Enum.map(fn version -> async_process_version(definition, scope, version, file) end)
      # |> IO.inspect()
      |> Task.yield_many(timeout: process_timeout, on_timeout: :kill_task)
      # |> IO.inspect()
      |> ensure_all_success()
      |> Enum.map(fn result -> async_put_version(definition, scope, result) end)
      |> Task.yield_many(timeout: process_timeout, on_timeout: :kill_task)
      # |> IO.inspect()
      |> handle_responses()
    else
      definition.__versions
      |> Enum.map(fn version -> process_version(definition, scope, version, file) end)
      |> ensure_all_success()
      |> Enum.map(fn result -> put_version(definition, scope, result) end)
      |> handle_responses()
    end
  end

  defp ensure_all_success(responses) do
    # TODO: optionally continue even if there's an error?
    errors =
      Enum.reject(responses, fn
        {%Task{}, {:ok, {_version, {:ok, _result}}}} -> true
        {%Task{}, _} -> false
        {_version, {:ok, _result}} -> true
        _ -> false
      end)

    if Enum.empty?(errors), do: responses, else: errors
  end

  defp handle_responses(ok: file) do
    {:ok,
     file
     |> struct(Bonfire.Files.Versions, ...)}
  end

  defp handle_responses(responses) do
    # errors = Enums.unwrap_tuples(responses, :error)
    {oks, errors} =
      Enum.split_with(responses, fn
        {%Task{}, {:ok, {:ok, _result}}} -> true
        {%Task{}, _} -> false
        {:ok, _result} -> true
        _ -> false
      end)

    if Enum.empty?(errors) do
      {
        :ok,
        #  Enums.unwrap_tuples(responses, :ok)
        oks
        |> Enum.map(fn
          {%Task{}, {:ok, {:ok, result}}} -> result
          {%Task{}, {:ok, result}} -> result
          result -> result
        end)
        |> Enums.deep_merge_reduce()
        |> struct(Bonfire.Files.Versions, ...)
      }
    else
      error(errors)
    end
  end

  defp version_timeout(definition) do
    # TODO: make sure spawed commands (eg ffmpeg are killed when timeout is reached)
    Utils.maybe_apply(definition, :transform_timeout, [],
      fallback_fun: fn -> Application.get_env(:waffle, :version_timeout) || 15_000 end
    )
  end

  defp async_process_version(definition, scope, version, file) do
    Task.async(fn ->
      process_version(definition, scope, version, file)
    end)
  end

  defp process_version(definition, scope, version, file) do
    {version, Processor.process(definition, version, {file, scope})}
  end

  defp async_put_version(definition, scope, result) do
    Task.async(fn ->
      put_version(definition, scope, result)
    end)
  end

  defp put_version(definition, scope, {%Task{}, {:ok, result}}),
    do: put_version(definition, scope, result)

  defp put_version(definition, scope, {%Task{}, nil}), do: error(:timeout)
  defp put_version(definition, scope, {%Task{}, other}), do: error(other)

  defp put_version(definition, scope, {version, result}) do
    case result do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, file} ->
        # returns file_name of transformation
        file_name = Versioning.resolve_file_name(definition, version, {file, scope})
        file = %Waffle.File{file | file_name: file_name}

        # result    = definition.__storage.put(definition, version, {file, scope})
        if binary = file.binary do
          destination_path = definition.url({file, scope}, version) |> String.trim_leading("/")
          Waffle.File.write!(destination_path, binary)
          %Waffle.File{file | path: destination_path}
        else
          file
        end

        # TODO?
        # case definition.transform(version, {file, scope}) do
        #   :noaction ->
        #     # We don't have to cleanup after `:noaction` transformations
        #     # because final `cleanup!` will remove the original temporary file.
        #     nil

        #   _ ->
        #     # cleanup!(file)
        #     nil
        # end

        # result
        {:ok,
         %{
           version => %{
             path: file.path,
             filename: file_name
           }
         }}

      nil ->
        error(:timeout)

      other ->
        error(other)
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
