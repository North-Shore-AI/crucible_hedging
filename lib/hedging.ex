defmodule CrucibleHedging do
  @moduledoc """
  Request hedging for tail latency reduction in distributed systems.

  Hedging reduces P99 latency by sending backup requests after a delay.
  When the primary request is slow, a backup request can complete first,
  significantly reducing tail latencies.

  ## Research Context

  Based on Google's "The Tail at Scale" research (Dean & Barroso, 2013),
  hedging can reduce P99 latency by 75-96% with only 5-10% cost overhead.

  ## Basic Usage

      # Simple hedging with fixed delay
      CrucibleHedging.request(
        fn -> make_api_call() end,
        strategy: :fixed,
        delay_ms: 100
      )

      # Percentile-based hedging (recommended)
      CrucibleHedging.request(
        fn -> make_api_call() end,
        strategy: :percentile,
        percentile: 95
      )

      # Adaptive learning
      CrucibleHedging.request(
        fn -> make_api_call() end,
        strategy: :adaptive
      )

  ## Options

  - `:strategy` - Strategy to use (`:fixed`, `:percentile`, `:adaptive`, `:workload_aware`)
  - `:delay_ms` - Fixed delay in milliseconds (for `:fixed` strategy)
  - `:percentile` - Target percentile (for `:percentile` strategy, default: 95)
  - `:max_hedges` - Maximum number of backup requests (default: 1)
  - `:timeout_ms` - Total request timeout (default: 30_000)
  - `:enable_cancellation` - Cancel slower requests (default: true)
  - `:telemetry_prefix` - Telemetry event prefix (default: `[:crucible_hedging]`)

  ## Return Value

  Returns `{:ok, result, metadata}` or `{:error, reason}`.

  Metadata includes:
  - `:hedged` - Whether a hedge was fired
  - `:hedge_won` - Whether the hedge completed first
  - `:total_latency` - Total request latency
  - `:primary_latency` - Primary request latency (if completed)
  - `:backup_latency` - Backup request latency (if fired)
  - `:hedge_delay` - Delay before hedge was sent
  """

  require Logger

  @type request_fn :: (-> any())
  @type opts :: keyword()
  @type result :: {:ok, any(), metadata :: map()} | {:error, any()}

  @default_opts [
    strategy: :percentile,
    percentile: 95,
    max_hedges: 1,
    timeout_ms: 30_000,
    enable_cancellation: true,
    telemetry_prefix: [:crucible_hedging]
  ]

  @doc """
  Executes a request with hedging to reduce tail latency.

  ## Examples

      iex> {:ok, result, metadata} = CrucibleHedging.request(fn -> :ok end, strategy: :fixed, delay_ms: 100)
      iex> result
      :ok
      iex> metadata.hedged
      false

      iex> {:ok, result, metadata} = CrucibleHedging.request(fn -> Process.sleep(150); :slow end, strategy: :fixed, delay_ms: 50)
      iex> result
      :slow
      iex> metadata.hedged
      true
  """
  @spec request(request_fn(), opts()) :: result()
  def request(request_fn, opts \\ []) when is_function(request_fn, 0) do
    opts = Keyword.merge(@default_opts, opts)
    start_time = System.monotonic_time(:millisecond)

    telemetry_prefix = Keyword.fetch!(opts, :telemetry_prefix)
    request_id = make_ref()

    # Emit telemetry start event
    :telemetry.execute(
      telemetry_prefix ++ [:request, :start],
      %{system_time: System.system_time()},
      %{request_id: request_id, strategy: opts[:strategy]}
    )

    try do
      result = execute_with_hedging(request_fn, opts, start_time, request_id, telemetry_prefix)

      # Emit telemetry stop event
      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      case result do
        {:ok, value, metadata} ->
          :telemetry.execute(
            telemetry_prefix ++ [:request, :stop],
            %{duration: duration},
            Map.merge(metadata, %{request_id: request_id})
          )

          # Update strategy with observed metrics
          strategy = CrucibleHedging.Strategy.get_strategy(opts[:strategy])
          strategy.update(metadata, nil)

          {:ok, value, Map.put(metadata, :total_latency, duration)}

        {:error, _reason} = error ->
          :telemetry.execute(
            telemetry_prefix ++ [:request, :exception],
            %{duration: duration},
            %{request_id: request_id}
          )

          error
      end
    rescue
      error ->
        Logger.error("Hedging request failed: #{inspect(error)}")
        {:error, error}
    end
  end

  # Private Functions

  defp execute_with_hedging(request_fn, opts, start_time, request_id, telemetry_prefix) do
    strategy = CrucibleHedging.Strategy.get_strategy(opts[:strategy])
    delay_ms = strategy.calculate_delay(opts)
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)

    # Start primary request
    primary_task =
      Task.async(fn ->
        try do
          result = request_fn.()
          completion_time = System.monotonic_time(:millisecond)
          latency = completion_time - start_time
          {:primary, result, latency, completion_time}
        rescue
          error ->
            {:error, error}
        end
      end)

    # Wait for hedge delay or primary completion
    case Task.yield(primary_task, delay_ms) do
      {:ok, {:primary, result, latency, _completion_time}} ->
        # Primary completed before hedge delay
        {:ok, result,
         %{
           hedged: false,
           hedge_won: false,
           primary_latency: latency,
           backup_latency: nil,
           hedge_delay: delay_ms,
           cost: 1.0
         }}

      {:ok, {:error, reason}} ->
        # Primary task failed
        Task.shutdown(primary_task, :brutal_kill)
        {:error, reason}

      {:exit, reason} ->
        # Primary task crashed
        Task.shutdown(primary_task, :brutal_kill)
        {:error, reason}

      nil ->
        # Primary still running, fire hedge
        fire_hedge(
          primary_task,
          request_fn,
          opts,
          start_time,
          delay_ms,
          timeout_ms,
          request_id,
          telemetry_prefix
        )
    end
  end

  defp fire_hedge(
         primary_task,
         request_fn,
         opts,
         start_time,
         delay_ms,
         timeout_ms,
         request_id,
         telemetry_prefix
       ) do
    # Emit hedge fired event
    :telemetry.execute(
      telemetry_prefix ++ [:hedge, :fired],
      %{delay: delay_ms},
      %{request_id: request_id}
    )

    hedge_start = System.monotonic_time(:millisecond)

    # Start backup request
    backup_task =
      Task.async(fn ->
        try do
          result = request_fn.()
          completion_time = System.monotonic_time(:millisecond)
          latency = completion_time - hedge_start
          {:backup, result, latency, completion_time}
        rescue
          error ->
            {:error, error}
        end
      end)

    # Race both requests
    remaining_timeout = max(0, timeout_ms - (hedge_start - start_time))

    tasks_with_results =
      [primary_task, backup_task]
      |> Task.yield_many(remaining_timeout)

    # Find first successful result
    case find_first_result(tasks_with_results) do
      {:ok, {winner, result, latency}} ->
        # Cancel slower task if enabled
        if Keyword.get(opts, :enable_cancellation, true) do
          cancel_slower_tasks(tasks_with_results, winner, telemetry_prefix, request_id)
        end

        hedge_won = winner == :backup

        if hedge_won do
          :telemetry.execute(
            telemetry_prefix ++ [:hedge, :won],
            %{latency: latency},
            %{request_id: request_id}
          )
        end

        {:ok, result,
         %{
           hedged: true,
           hedge_won: hedge_won,
           primary_latency: if(winner == :primary, do: latency, else: nil),
           backup_latency: if(winner == :backup, do: latency, else: nil),
           hedge_delay: delay_ms,
           cost: if(hedge_won, do: 1.0, else: 2.0)
         }}

      {:error, _reason} = error ->
        # Both tasks failed or timed out
        Task.shutdown(primary_task, :brutal_kill)
        Task.shutdown(backup_task, :brutal_kill)
        error
    end
  end

  defp find_first_result(tasks_with_results) do
    # Collect all successful results with their completion times
    successful_results =
      tasks_with_results
      |> Enum.filter(fn
        {_task, {:ok, {:error, _reason}}} -> false
        {_task, {:ok, {_tag, _result, _latency, _completion_time}}} -> true
        {_task, _} -> false
      end)
      |> Enum.map(fn {_task, {:ok, result}} -> result end)

    case successful_results do
      [] ->
        {:error, :all_tasks_failed}

      results ->
        # Sort by completion time and return the first one
        {tag, result, latency, _completion_time} =
          results
          |> Enum.min_by(fn {_tag, _result, _latency, completion_time} -> completion_time end)

        {:ok, {tag, result, latency}}
    end
  end

  defp cancel_slower_tasks(tasks_with_results, winner, telemetry_prefix, request_id) do
    tasks_with_results
    |> Enum.each(fn
      {_task, {:ok, {^winner, _result, _latency}}} ->
        # This is the winner, don't cancel
        nil

      {task, _} ->
        # Cancel this task
        Task.shutdown(task, :brutal_kill)

        :telemetry.execute(
          telemetry_prefix ++ [:request, :cancelled],
          %{},
          %{request_id: request_id}
        )
    end)
  end
end
