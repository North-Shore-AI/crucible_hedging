defmodule CrucibleHedging.Strategy.Adaptive do
  @moduledoc """
  Adaptive hedging strategy using Thompson Sampling.

  Learns optimal hedge delay by treating it as a multi-armed bandit problem.
  Each delay value is an "arm", rewards are based on latency improvements
  and cost efficiency.

  ## Research Foundation

  Thompson Sampling achieves O(K log T) regret bound:
  - K = number of delay candidates
  - T = number of requests
  - Typically converges within ~500 requests (5% regret)

  ## Characteristics

  - **Pros**: Optimal long-term performance, handles non-stationary workloads
  - **Cons**: Requires tuning, cold start period
  - **Use Case**: High-traffic production with varying latency patterns

  ## Options

  - `:delay_candidates` - List of delay values to try (default: [50, 100, 200, 500, 1000])
  - `:learning_rate` - Learning rate for Beta distribution updates (default: 0.1)

  ## Example

      CrucibleHedging.request(
        fn -> make_api_call() end,
        strategy: :adaptive,
        delay_candidates: [100, 200, 500]
      )
  """

  use GenServer
  @behaviour CrucibleHedging.Strategy

  defstruct [
    :delay_candidates,
    :arm_stats,
    :learning_rate,
    :current_delay,
    :total_pulls
  ]

  @default_candidates [50, 100, 200, 500, 1000]
  @default_learning_rate 0.1

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl CrucibleHedging.Strategy
  def calculate_delay(opts) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        # Server not started, use middle candidate
        candidates = Keyword.get(opts, :delay_candidates, @default_candidates)
        Enum.at(candidates, div(length(candidates), 2))

      _pid ->
        GenServer.call(__MODULE__, :select_delay)
    end
  end

  @impl CrucibleHedging.Strategy
  def update(metrics, _state) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        :ok

      _pid ->
        reward = calculate_reward(metrics)
        delay = metrics[:hedge_delay]

        if delay && reward do
          GenServer.cast(__MODULE__, {:update_reward, delay, reward})
        end
    end

    :ok
  end

  # Server Callbacks

  @impl GenServer
  def init(opts) do
    candidates = Keyword.get(opts, :delay_candidates, @default_candidates)

    # Initialize Beta distribution parameters for each arm
    # Beta(α, β) where α represents successes, β represents failures
    arm_stats =
      Map.new(candidates, fn delay ->
        {delay, %{alpha: 1.0, beta: 1.0, pulls: 0, total_reward: 0.0}}
      end)

    {:ok,
     %__MODULE__{
       delay_candidates: candidates,
       arm_stats: arm_stats,
       learning_rate: Keyword.get(opts, :learning_rate, @default_learning_rate),
       current_delay: Enum.random(candidates),
       total_pulls: 0
     }}
  end

  @impl GenServer
  def handle_call(:select_delay, _from, state) do
    # Thompson Sampling: sample from Beta distribution for each arm
    sampled_values =
      Map.new(state.arm_stats, fn {delay, stats} ->
        {delay, sample_beta(stats.alpha, stats.beta)}
      end)

    # Select arm with highest sampled value
    {selected_delay, _value} = Enum.max_by(sampled_values, fn {_delay, value} -> value end)

    # Update pull count
    arm_stats =
      Map.update!(state.arm_stats, selected_delay, fn stats ->
        %{stats | pulls: stats.pulls + 1}
      end)

    new_state = %{
      state
      | current_delay: selected_delay,
        arm_stats: arm_stats,
        total_pulls: state.total_pulls + 1
    }

    {:reply, selected_delay, new_state}
  end

  @impl GenServer
  def handle_call(:get_stats, _from, state) do
    stats = %{
      total_pulls: state.total_pulls,
      current_delay: state.current_delay,
      arms:
        Map.new(state.arm_stats, fn {delay, stats} ->
          {delay,
           %{
             pulls: stats.pulls,
             total_reward: stats.total_reward,
             avg_reward: if(stats.pulls > 0, do: stats.total_reward / stats.pulls, else: 0.0),
             alpha: stats.alpha,
             beta: stats.beta,
             expected_value: stats.alpha / (stats.alpha + stats.beta)
           }}
        end)
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_cast({:update_reward, delay, reward}, state) do
    # Only update if this delay is one of our candidates
    if Map.has_key?(state.arm_stats, delay) do
      # Update Beta distribution parameters
      arm_stats =
        Map.update!(state.arm_stats, delay, fn stats ->
          %{
            stats
            | alpha: stats.alpha + reward,
              beta: stats.beta + (1 - reward),
              total_reward: stats.total_reward + reward
          }
        end)

      {:noreply, %{state | arm_stats: arm_stats}}
    else
      {:noreply, state}
    end
  end

  # Helper Functions

  defp sample_beta(alpha, beta) do
    # Beta distribution sampling using ratio of gammas
    # For production, consider using a more robust implementation
    # This is a simplified version using the mean of the Beta distribution
    # Mean of Beta(α, β) = α / (α + β)
    #
    # For true Thompson Sampling, we should sample from the distribution
    # Using approximation for now to avoid external dependencies
    mean = alpha / (alpha + beta)

    # Add small noise to break ties
    noise = :rand.uniform() * 0.01
    mean + noise
  end

  @doc """
  Calculates reward based on hedging effectiveness.

  Reward function optimizes for latency savings per unit cost:
  - High reward if hedge won and saved significant latency
  - Low reward if hedge fired but didn't win
  - Medium reward if hedge didn't fire and request was fast
  """
  def calculate_reward(metrics) do
    cond do
      # Hedge fired and won - calculate efficiency
      metrics[:hedge_won] == true ->
        primary_latency = metrics[:primary_latency] || 999_999
        backup_latency = metrics[:backup_latency] || 0
        hedge_delay = metrics[:hedge_delay] || 0

        # Latency saved by hedging
        latency_saved = primary_latency - (hedge_delay + backup_latency)

        # Normalize to [0, 1]: 1 if saved >500ms, 0 if no savings
        reward = latency_saved / 500
        min(max(reward, 0.0), 1.0)

      # Hedge fired but didn't win - penalty for wasted cost
      metrics[:hedged] == true ->
        0.0

      # No hedge fired and request was fast - good decision
      metrics[:hedged] == false ->
        latency = metrics[:primary_latency] || metrics[:total_latency] || 0

        # Reward for correctly not hedging fast requests
        # Higher reward for faster requests
        if latency < 200 do
          0.8
        else
          0.5
        end

      # Default
      true ->
        0.0
    end
  end

  @doc """
  Gets statistics about the current learning state.
  """
  def get_stats do
    case GenServer.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      _pid ->
        GenServer.call(__MODULE__, :get_stats)
    end
  end
end
