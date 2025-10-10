defmodule CrucibleHedging.Metrics do
  @moduledoc """
  Metrics collection and percentile calculation for hedging effectiveness.

  This module provides utilities for:
  - Collecting request latency distributions
  - Calculating percentiles (P50, P90, P95, P99)
  - Tracking hedge effectiveness (hit rate, cost overhead)
  - Computing cost vs latency tradeoffs

  ## Usage

      # Start the metrics collector
      {:ok, pid} = CrucibleHedging.Metrics.start_link()

      # Record metrics
      CrucibleHedging.Metrics.record(%{
        latency: 150,
        hedged: true,
        hedge_won: true,
        cost: 1.5
      })

      # Get statistics
      stats = CrucibleHedging.Metrics.get_stats()
      # => %{
      #   total_requests: 1000,
      #   hedge_rate: 0.15,
      #   hedge_win_rate: 0.75,
      #   p50_latency: 120,
      #   p99_latency: 450,
      #   avg_cost: 1.08
      # }
  """

  use GenServer

  defstruct [
    :latencies,
    :window_size,
    :total_requests,
    :hedged_requests,
    :hedge_wins,
    :total_cost,
    :started_at
  ]

  @default_window_size 10_000

  # Client API

  @doc """
  Starts the metrics collector.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records metrics from a hedging request.
  """
  def record(metrics) when is_map(metrics) do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:record, metrics})
    end
  end

  @doc """
  Gets current statistics.
  """
  def get_stats do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, :get_stats)
    end
  end

  @doc """
  Resets all metrics.
  """
  def reset do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, :reset)
    end
  end

  # Server Callbacks

  @impl GenServer
  def init(opts) do
    {:ok,
     %__MODULE__{
       latencies: :queue.new(),
       window_size: Keyword.get(opts, :window_size, @default_window_size),
       total_requests: 0,
       hedged_requests: 0,
       hedge_wins: 0,
       total_cost: 0.0,
       started_at: System.monotonic_time(:millisecond)
     }}
  end

  @impl GenServer
  def handle_cast({:record, metrics}, state) do
    latency = metrics[:total_latency] || metrics[:latency] || 0
    hedged = metrics[:hedged] || false
    hedge_won = metrics[:hedge_won] || false
    cost = metrics[:cost] || 1.0

    # Add latency to rolling window
    latencies = :queue.in(latency, state.latencies)

    latencies =
      if :queue.len(latencies) > state.window_size do
        {_, trimmed} = :queue.out(latencies)
        trimmed
      else
        latencies
      end

    # Update counters
    new_state = %{
      state
      | latencies: latencies,
        total_requests: state.total_requests + 1,
        hedged_requests: state.hedged_requests + if(hedged, do: 1, else: 0),
        hedge_wins: state.hedge_wins + if(hedge_won, do: 1, else: 0),
        total_cost: state.total_cost + cost
    }

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_cast(:reset, state) do
    {:noreply,
     %{
       state
       | latencies: :queue.new(),
         total_requests: 0,
         hedged_requests: 0,
         hedge_wins: 0,
         total_cost: 0.0,
         started_at: System.monotonic_time(:millisecond)
     }}
  end

  @impl GenServer
  def handle_call(:get_stats, _from, state) do
    latencies_list = :queue.to_list(state.latencies)
    sorted_latencies = Enum.sort(latencies_list)

    stats = %{
      # Request counts
      total_requests: state.total_requests,
      sample_count: length(latencies_list),
      hedged_requests: state.hedged_requests,
      hedge_wins: state.hedge_wins,
      # Rates
      hedge_rate: safe_divide(state.hedged_requests, state.total_requests),
      hedge_win_rate: safe_divide(state.hedge_wins, state.hedged_requests),
      hedge_effectiveness: safe_divide(state.hedge_wins, state.total_requests),
      # Latency percentiles
      p50_latency: calculate_percentile(sorted_latencies, 50),
      p90_latency: calculate_percentile(sorted_latencies, 90),
      p95_latency: calculate_percentile(sorted_latencies, 95),
      p99_latency: calculate_percentile(sorted_latencies, 99),
      p999_latency: calculate_percentile(sorted_latencies, 99.9),
      # Latency stats
      min_latency: if(length(sorted_latencies) > 0, do: List.first(sorted_latencies), else: 0),
      max_latency: if(length(sorted_latencies) > 0, do: List.last(sorted_latencies), else: 0),
      mean_latency: calculate_mean(sorted_latencies),
      median_latency: calculate_percentile(sorted_latencies, 50),
      # Cost metrics
      total_cost: state.total_cost,
      avg_cost: safe_divide(state.total_cost, state.total_requests),
      cost_overhead:
        calculate_cost_overhead(state.total_cost, state.total_requests, state.hedge_wins),
      # Time metrics
      uptime_ms: System.monotonic_time(:millisecond) - state.started_at,
      requests_per_second:
        safe_divide(
          state.total_requests * 1000,
          System.monotonic_time(:millisecond) - state.started_at
        )
    }

    {:reply, stats, state}
  end

  # Helper Functions

  defp calculate_percentile([], _percentile), do: 0

  defp calculate_percentile(sorted_list, percentile) do
    len = length(sorted_list)
    index = max(0, ceil(len * percentile / 100) - 1)
    Enum.at(sorted_list, index, 0)
  end

  defp calculate_mean([]), do: 0.0

  defp calculate_mean(list) do
    sum = Enum.sum(list)
    len = length(list)
    sum / len
  end

  defp safe_divide(_numerator, 0), do: 0.0
  defp safe_divide(numerator, denominator), do: numerator / denominator

  defp calculate_cost_overhead(total_cost, total_requests, _hedge_wins) do
    if total_requests > 0 do
      # Cost overhead = (actual cost - baseline cost) / baseline cost
      # Baseline cost assumes no hedging (cost = total_requests)
      # Actual cost includes hedge wins (which cost ~2x) and non-hedges (which cost 1x)
      baseline_cost = total_requests * 1.0
      overhead = (total_cost - baseline_cost) / baseline_cost
      Float.round(overhead * 100, 2)
    else
      0.0
    end
  end

  @doc """
  Calculates percentile from a list of values.

  This is a utility function that can be used independently.
  """
  @spec percentile([number()], number()) :: number()
  def percentile(values, percentile) when is_list(values) and is_number(percentile) do
    sorted = Enum.sort(values)
    calculate_percentile(sorted, percentile)
  end

  @doc """
  Calculates multiple percentiles at once.

  ## Example

      iex> CrucibleHedging.Metrics.percentiles([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], [50, 90, 95])
      %{50 => 5, 90 => 9, 95 => 10}
  """
  @spec percentiles([number()], [number()]) :: %{number() => number()}
  def percentiles(values, percentile_list)
      when is_list(values) and is_list(percentile_list) do
    sorted = Enum.sort(values)

    Map.new(percentile_list, fn p ->
      {p, calculate_percentile(sorted, p)}
    end)
  end
end
