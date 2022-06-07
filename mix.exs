defmodule BonfireFiles.MixProject do
  use Mix.Project

  def project do
    [
      app: :bonfire_files,
      version: "0.1.0",
      elixir: "~> 1.11",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: Mess.deps [
        {:tree_magic, git: "https://github.com/bonfire-networks/tree_magic.ex", optional: true},
        {:bonfire_api_graphql, git: "https://github.com/bonfire-networks/bonfire_api_graphql", branch: "main", optional: true},
        {:ex_aws_s3, "~> 2.3", optional: true}
      ]
    ]
  end

  def application, do: [ extra_applications: [:logger] ]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
