defmodule CrucibleHedging.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Metrics collector
      {CrucibleHedging.Metrics, []}
      # Strategy GenServers (started on-demand, but can be pre-started)
      # {CrucibleHedging.Strategy.Percentile, []},
      # {CrucibleHedging.Strategy.Adaptive, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CrucibleHedging.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
