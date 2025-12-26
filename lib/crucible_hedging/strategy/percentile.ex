defmodule CrucibleHedging.Strategy.Percentile do
  @moduledoc """
  Percentile-based hedging strategy with rolling window.

  Hedges at the Xth percentile of historical latency distribution.
  This is Google's recommended approach based on production BigTable results.

  ## Research Foundation

  Google's "The Tail at Scale" paper recommends hedging at P95:
  - 96% P99 latency reduction
  - Only 5% resource overhead
  - Optimal balance of cost vs latency improvement

  ## Characteristics

  - **Pros**: Adapts to workload, proven in production
  - **Cons**: Requires warmup period, sensitive to outliers
  - **Use Case**: Production systems with sufficient traffic

  ## Options

  - `:percentile` - Target percentile (default: 95, range: 50-99)
  - `:window_size` - Rolling window size (default: 1000)
  - `:initial_delay` - Initial delay before warmup (default: 100ms)

  ## Example

      CrucibleHedging.request(
        fn -> make_api_call() end,
        strategy: :percentile,
        percentile: 90,
        window_size: 500
      )
  """

  use GenServer
  @behaviour CrucibleHedging.Strategy

  defstruct [
    :percentile,
    :window_size,
    :latencies,
    :current_delay,
    :min_samples
  ]

  @default_percentile 95
  @default_window_size 1000
  @default_initial_delay 100
  @min_samples_required 10

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl CrucibleHedging.Strategy
  def calculate_delay(opts) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        # Server not started, use initial delay
        Keyword.get(opts, :initial_delay, @default_initial_delay)

      _pid ->
        GenServer.call(__MODULE__, :get_delay)
    end
  end

  @impl CrucibleHedging.Strategy
  def update(metrics, _state) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        :ok

      _pid ->
        latency =
          metrics[:primary_latency] || metrics[:backup_latency] || metrics[:latency] ||
            metrics[:total_latency]

        if latency do
          GenServer.cast(__MODULE__, {:update, latency})
        end
    end

    :ok
  end

  # Server Callbacks

  @impl GenServer
  def init(opts) do
    {:ok,
     %__MODULE__{
       percentile: Keyword.get(opts, :percentile, @default_percentile),
       window_size: Keyword.get(opts, :window_size, @default_window_size),
       latencies: :queue.new(),
       current_delay: Keyword.get(opts, :initial_delay, @default_initial_delay),
       min_samples: Keyword.get(opts, :min_samples, @min_samples_required)
     }}
  end

  @impl GenServer
  def handle_call(:get_delay, _from, state) do
    {:reply, state.current_delay, state}
  end

  @impl GenServer
  def handle_call(:get_stats, _from, state) do
    latencies_list = :queue.to_list(state.latencies)
    sorted = Enum.sort(latencies_list)
    len = length(sorted)

    stats =
      if len > 0 do
        %{
          sample_count: len,
          current_delay: state.current_delay,
          percentile: state.percentile,
          p50: calculate_percentile_value(sorted, 50),
          p90: calculate_percentile_value(sorted, 90),
          p95: calculate_percentile_value(sorted, 95),
          p99: calculate_percentile_value(sorted, 99),
          min: List.first(sorted),
          max: List.last(sorted),
          mean: div(Enum.sum(sorted), len)
        }
      else
        %{
          sample_count: 0,
          current_delay: state.current_delay,
          percentile: state.percentile
        }
      end

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_cast({:update, latency}, state) when is_integer(latency) and latency > 0 do
    # Add new latency to rolling window
    latencies = :queue.in(latency, state.latencies)

    # Trim to window size
    latencies =
      if :queue.len(latencies) > state.window_size do
        {_, trimmed} = :queue.out(latencies)
        trimmed
      else
        latencies
      end

    # Calculate new delay if we have enough samples
    current_delay =
      if :queue.len(latencies) >= state.min_samples do
        calculate_percentile_delay(latencies, state.percentile)
      else
        state.current_delay
      end

    {:noreply, %{state | latencies: latencies, current_delay: current_delay}}
  end

  @impl GenServer
  def handle_cast({:update, _invalid_latency}, state) do
    # Ignore invalid latency values
    {:noreply, state}
  end

  # Helper Functions

  defp calculate_percentile_delay(latencies, percentile) do
    sorted =
      latencies
      |> :queue.to_list()
      |> Enum.sort()

    len = length(sorted)

    if len == 0 do
      @default_initial_delay
    else
      # Calculate percentile index
      # Using nearest-rank method
      index = max(0, ceil(len * percentile / 100) - 1)
      Enum.at(sorted, index, @default_initial_delay)
    end
  end

  @doc """
  Gets statistics about the current state.
  """
  def get_stats do
    case GenServer.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      _pid ->
        GenServer.call(__MODULE__, :get_stats)
    end
  end

  defp calculate_percentile_value([], _percentile), do: 0

  defp calculate_percentile_value(sorted, percentile) do
    len = length(sorted)
    index = max(0, ceil(len * percentile / 100) - 1)
    Enum.at(sorted, index, 0)
  end
end
