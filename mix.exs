Code.eval_file("mess.exs", (if File.exists?("../../lib/mix/mess.exs"), do: "../../lib/mix/"))

defmodule Bonfire.Files.MixProject do
  use Mix.Project

  def project do
    if System.get_env("AS_UMBRELLA") == "1" do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
    ++
    [
      app: :bonfire_files,
      version: "0.1.0",
      elixir: "~> 1.11",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps:
        Mess.deps([
          {:bonfire_api_graphql,
           git: "https://github.com/bonfire-networks/bonfire_api_graphql",
           branch: "main",
           optional: true, runtime: false},
          {:image, "~> 0.37", optional: true},
          {:ex_aws_s3, "~> 2.3", optional: true},
          {:blurhash, "~> 0.1.0", hex: :rinpatch_blurhash}
        ])
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
