defmodule CrucibleHedging.Strategy do
  @moduledoc """
  Behaviour for hedge delay calculation strategies.

  A strategy determines when to send backup requests by calculating
  optimal hedge delays based on historical latency patterns.

  ## Callbacks

  - `calculate_delay/1` - Returns the delay in milliseconds before sending a hedge request
  - `update/2` - Updates strategy state based on observed metrics

  ## Built-in Strategies

  - `CrucibleHedging.Strategy.Fixed` - Simple fixed delay
  - `CrucibleHedging.Strategy.Percentile` - Percentile-based with rolling window
  - `CrucibleHedging.Strategy.Adaptive` - Thompson Sampling based learning
  - `CrucibleHedging.Strategy.WorkloadAware` - Context-sensitive hedging
  """

  @type opts :: keyword()
  @type delay_ms :: non_neg_integer()
  @type metrics :: %{
          latency: non_neg_integer(),
          hedge_fired: boolean(),
          hedge_won: boolean(),
          hedge_delay: non_neg_integer(),
          primary_latency: non_neg_integer() | nil,
          backup_latency: non_neg_integer() | nil,
          cost: float(),
          timestamp: integer()
        }
  @type state :: any()

  @doc """
  Calculates the hedge delay in milliseconds.

  This is called before each request to determine how long to wait
  before sending a backup request.
  """
  @callback calculate_delay(opts) :: delay_ms()

  @doc """
  Updates strategy state based on observed metrics.

  This is called after each request completes to allow the strategy
  to learn and adapt.
  """
  @callback update(metrics, state) :: state()

  @doc """
  Returns the appropriate strategy module based on the strategy name.
  """
  @spec get_strategy(atom()) :: module()
  def get_strategy(:fixed), do: CrucibleHedging.Strategy.Fixed
  def get_strategy(:percentile), do: CrucibleHedging.Strategy.Percentile
  def get_strategy(:adaptive), do: CrucibleHedging.Strategy.Adaptive
  def get_strategy(:workload_aware), do: CrucibleHedging.Strategy.WorkloadAware
  def get_strategy(:exponential_backoff), do: CrucibleHedging.Strategy.ExponentialBackoff
  def get_strategy(module) when is_atom(module), do: module
end
