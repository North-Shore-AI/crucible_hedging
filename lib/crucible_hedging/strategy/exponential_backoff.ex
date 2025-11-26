defmodule CrucibleHedging.Strategy.ExponentialBackoff do
  @moduledoc """
  Exponential backoff strategy for handling transient failures and bursty traffic.

  Dynamically adjusts hedge delay based on success/failure patterns, similar to TCP congestion control.
  This strategy is particularly effective for:

  - Services with transient failures
  - Rate-limited APIs that need adaptive backoff
  - Bursty traffic patterns
  - Services experiencing temporary degradation

  ## Algorithm

  The strategy maintains a current delay that adjusts based on request outcomes:

  - **On hedge_won** (hedge saved latency): `delay *= decrease_factor` (default: 0.9)
  - **On hedge_lost** (hedge wasted cost): `delay *= increase_factor` (default: 1.5)
  - **On error**: `delay *= error_factor` (default: 2.0)
  - **Clamped** to `[min_delay, max_delay]` range

  ## Characteristics

  - **Pros**: Adapts to service health, reduces load during failures, no warmup needed
  - **Cons**: Slower to adapt than percentile-based, requires tuning
  - **Use Case**: Rate-limited APIs, services with variable health, cost-sensitive workloads

  ## Options

  - `:base_delay` - Initial delay in milliseconds (default: 100)
  - `:min_delay` - Minimum delay floor (default: 10)
  - `:max_delay` - Maximum delay ceiling (default: 5000)
  - `:increase_factor` - Multiplier on failures (default: 1.5)
  - `:decrease_factor` - Multiplier on successes (default: 0.9)
  - `:error_factor` - Multiplier on errors (default: 2.0)

  ## Example

      # Start the strategy
      {:ok, _pid} = CrucibleHedging.Strategy.ExponentialBackoff.start_link(
        base_delay: 100,
        max_delay: 5000
      )

      # Make requests - strategy learns from outcomes
      CrucibleHedging.request(
        fn -> rate_limited_api_call() end,
        strategy: :exponential_backoff
      )

  ## Research Foundation

  Based on TCP congestion control algorithms (AIMD - Additive Increase Multiplicative Decrease)
  and exponential backoff in distributed systems (Ethernet, HTTP retries).

  ## Performance

  Typical behavior:
  - Starts at base_delay (100ms)
  - After 5 failures: ~759ms delay
  - After 10 failures: ~5000ms (clamped to max)
  - Recovers gradually on successes
  """

  use GenServer
  @behaviour CrucibleHedging.Strategy

  defstruct [
    :current_delay,
    :base_delay,
    :min_delay,
    :max_delay,
    :increase_factor,
    :decrease_factor,
    :error_factor,
    :consecutive_successes,
    :consecutive_failures,
    :total_adjustments
  ]

  @default_base_delay 100
  @default_min_delay 10
  @default_max_delay 5000
  @default_increase_factor 1.5
  @default_decrease_factor 0.9
  @default_error_factor 2.0

  defp get_name(opts) do
    Keyword.get(opts, :strategy_name) ||
      Keyword.get(opts, :name) ||
      __MODULE__
  end

  defp to_opts(data) when is_map(data), do: Map.to_list(data)
  defp to_opts(data) when is_list(data), do: data
  defp to_opts(_other), do: []

  defp normalize_opts(opts) do
    [
      base_delay:
        Keyword.get(
          opts,
          :exponential_base_delay,
          Keyword.get(opts, :base_delay, @default_base_delay)
        ),
      min_delay:
        Keyword.get(
          opts,
          :exponential_min_delay,
          Keyword.get(opts, :min_delay, @default_min_delay)
        ),
      max_delay:
        Keyword.get(
          opts,
          :exponential_max_delay,
          Keyword.get(opts, :max_delay, @default_max_delay)
        ),
      increase_factor:
        Keyword.get(
          opts,
          :exponential_increase_factor,
          Keyword.get(opts, :increase_factor, @default_increase_factor)
        ),
      decrease_factor:
        Keyword.get(
          opts,
          :exponential_decrease_factor,
          Keyword.get(opts, :decrease_factor, @default_decrease_factor)
        ),
      error_factor:
        Keyword.get(
          opts,
          :exponential_error_factor,
          Keyword.get(opts, :error_factor, @default_error_factor)
        )
    ]
  end

  defp ensure_started(opts) do
    opts = to_opts(opts)
    name = get_name(opts)

    case GenServer.whereis(name) do
      nil ->
        start_opts =
          opts
          |> normalize_opts()
          |> Keyword.put(:name, name)

        case start_link(start_opts) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, _reason} -> :error
        end

      _pid ->
        :ok
    end
  end

  # Client API

  @doc """
  Starts the exponential backoff strategy GenServer.

  ## Options

  - `:base_delay` - Initial delay (default: 100ms)
  - `:min_delay` - Minimum delay (default: 10ms)
  - `:max_delay` - Maximum delay (default: 5000ms)
  - `:increase_factor` - Failure multiplier (default: 1.5)
  - `:decrease_factor` - Success multiplier (default: 0.9)
  - `:error_factor` - Error multiplier (default: 2.0)
  - `:name` - GenServer name (default: __MODULE__)
  """
  def start_link(opts \\ []) do
    opts = normalize_opts(opts) |> Keyword.merge(opts)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl CrucibleHedging.Strategy
  def calculate_delay(opts) when is_list(opts) do
    name = get_name(opts)

    case ensure_started(opts) do
      :ok ->
        GenServer.call(name, :get_delay)

      :error ->
        # Fall back to default if we couldn't start
        Keyword.get(opts, :exponential_base_delay, @default_base_delay)
    end
  end

  def calculate_delay(opts), do: calculate_delay(to_opts(opts))

  @impl CrucibleHedging.Strategy
  def update(metrics, _state) do
    opts = to_opts(metrics)
    name = get_name(opts)

    case ensure_started(opts) do
      :error ->
        :ok

      :ok ->
        cond do
          # Hedge won - saved latency, can be more aggressive
          metrics[:hedge_won] == true ->
            GenServer.cast(name, :success)

          # Hedge fired but didn't win - wasted cost, back off
          metrics[:hedged] == true and not metrics[:hedge_won] ->
            GenServer.cast(name, :failure)

          # Error occurred - aggressive backoff
          Map.has_key?(metrics, :error) ->
            GenServer.cast(name, :error)

          # No hedge fired and request was fast - good decision
          metrics[:hedged] == false ->
            GenServer.cast(name, :success)

          true ->
            :ok
        end
    end

    :ok
  end

  @doc """
  Gets current strategy statistics.

  Returns a map with:
  - `:current_delay` - Current hedge delay in ms
  - `:consecutive_successes` - Streak of successful outcomes
  - `:consecutive_failures` - Streak of failed outcomes
  - `:total_adjustments` - Total number of delay adjustments
  - `:min_delay` - Configured minimum
  - `:max_delay` - Configured maximum
  """
  def get_stats(name \\ __MODULE__) do
    case GenServer.whereis(name) do
      nil ->
        {:error, :not_started}

      _pid ->
        GenServer.call(name, :get_stats)
    end
  end

  @doc """
  Resets the strategy to initial state.
  """
  def reset(name \\ __MODULE__) do
    case GenServer.whereis(name) do
      nil -> :ok
      _pid -> GenServer.cast(name, :reset)
    end
  end

  # Server Callbacks

  @impl GenServer
  def init(opts) do
    base_delay = Keyword.get(opts, :base_delay, @default_base_delay)

    {:ok,
     %__MODULE__{
       current_delay: base_delay,
       base_delay: base_delay,
       min_delay: Keyword.get(opts, :min_delay, @default_min_delay),
       max_delay: Keyword.get(opts, :max_delay, @default_max_delay),
       increase_factor: Keyword.get(opts, :increase_factor, @default_increase_factor),
       decrease_factor: Keyword.get(opts, :decrease_factor, @default_decrease_factor),
       error_factor: Keyword.get(opts, :error_factor, @default_error_factor),
       consecutive_successes: 0,
       consecutive_failures: 0,
       total_adjustments: 0
     }}
  end

  @impl GenServer
  def handle_call(:get_delay, _from, state) do
    {:reply, round(state.current_delay), state}
  end

  @impl GenServer
  def handle_call(:get_stats, _from, state) do
    stats = %{
      current_delay: round(state.current_delay),
      base_delay: state.base_delay,
      min_delay: state.min_delay,
      max_delay: state.max_delay,
      consecutive_successes: state.consecutive_successes,
      consecutive_failures: state.consecutive_failures,
      total_adjustments: state.total_adjustments,
      increase_factor: state.increase_factor,
      decrease_factor: state.decrease_factor,
      error_factor: state.error_factor
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_cast(:success, state) do
    # Multiplicative decrease on success
    new_delay =
      max(
        state.min_delay,
        state.current_delay * state.decrease_factor
      )

    {:noreply,
     %{
       state
       | current_delay: new_delay,
         consecutive_successes: state.consecutive_successes + 1,
         consecutive_failures: 0,
         total_adjustments: state.total_adjustments + 1
     }}
  end

  @impl GenServer
  def handle_cast(:failure, state) do
    # Multiplicative increase on failure
    new_delay =
      min(
        state.max_delay,
        state.current_delay * state.increase_factor
      )

    {:noreply,
     %{
       state
       | current_delay: new_delay,
         consecutive_failures: state.consecutive_failures + 1,
         consecutive_successes: 0,
         total_adjustments: state.total_adjustments + 1
     }}
  end

  @impl GenServer
  def handle_cast(:error, state) do
    # Aggressive increase on error
    new_delay =
      min(
        state.max_delay,
        state.current_delay * state.error_factor
      )

    {:noreply,
     %{
       state
       | current_delay: new_delay,
         consecutive_failures: state.consecutive_failures + 1,
         consecutive_successes: 0,
         total_adjustments: state.total_adjustments + 1
     }}
  end

  @impl GenServer
  def handle_cast(:reset, state) do
    {:noreply,
     %{
       state
       | current_delay: state.base_delay,
         consecutive_successes: 0,
         consecutive_failures: 0,
         total_adjustments: 0
     }}
  end
end
