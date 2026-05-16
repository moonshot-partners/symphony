defmodule SymphonyElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          SymphonyElixir.Agent.AppServer,
          SymphonyElixir.Agent.AppServer.Approval,
          SymphonyElixir.Agent.AppServer.Transport,
          SymphonyElixir.Agent.AppServer.Turn,
          SymphonyElixir.Agent.DynamicTool,
          SymphonyElixir.AgentRunner,
          SymphonyElixir.Application,
          SymphonyElixir.CLI,
          SymphonyElixir.Config,
          SymphonyElixir.GitHubPr,
          SymphonyElixir.Linear.Adapter,
          SymphonyElixir.Linear.Client,
          SymphonyElixir.Linear.FileUpload,
          SymphonyElixir.LogFile,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.Orchestrator.Dispatch,
          SymphonyElixir.Orchestrator.GithubLabel,
          SymphonyElixir.Orchestrator.PrMerge,
          SymphonyElixir.Orchestrator.StateTransition,
          SymphonyElixir.Orchestrator.TokenMetrics,
          SymphonyElixir.QaEvidence,
          SymphonyElixir.Workflow,
          SymphonyElixir.Workpad,
          SymphonyElixir.Workspace
        ]
      ],
      test_ignore_filters: [
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      escript: escript(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {SymphonyElixir.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:ecto, "~> 3.13"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      lint: ["credo --strict"]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: SymphonyElixir.CLI,
      name: "symphony",
      path: "bin/symphony"
    ]
  end
end
