defmodule CrucibleHedging.Strategy.Fixed do
  @moduledoc """
  Fixed delay hedging strategy.

  Waits a constant duration before sending a backup request.
  This is the simplest strategy, useful for development and testing,
  or for systems with very predictable latency.

  ## Characteristics

  - **Pros**: Simple, predictable, no learning required
  - **Cons**: Suboptimal for varying workloads
  - **Use Case**: Development, testing, highly predictable services

  ## Options

  - `:delay_ms` - Fixed delay in milliseconds (default: 100)

  ## Example

      CrucibleHedging.request(
        fn -> make_api_call() end,
        strategy: :fixed,
        delay_ms: 200
      )
  """

  @behaviour CrucibleHedging.Strategy

  @default_delay_ms 100

  @impl CrucibleHedging.Strategy
  def calculate_delay(opts) do
    Keyword.get(opts, :delay_ms, @default_delay_ms)
  end

  @impl CrucibleHedging.Strategy
  def update(_metrics, state), do: state
end
