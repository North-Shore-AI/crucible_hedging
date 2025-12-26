defmodule CrucibleHedging.MultiLevel do
  @moduledoc """
  Multi-tier hedging with progressively cheaper or faster alternatives.

  This module implements cascading hedging across multiple tiers, allowing
  you to start with a high-quality/high-latency option and progressively
  fall back to faster alternatives.

  ## Use Cases

  - **Quality-first with fallback**: Try GPT-4, fall back to GPT-3.5, then Gemini Flash
  - **Geographic redundancy**: Try US-East, fall back to US-West, then EU
  - **Service degradation**: Try primary API, fall back to backup, then cache

  ## Cost Analysis

  Multi-level hedging can actually reduce costs while improving latency:

  Example: GPT-4 → GPT-3.5 → Gemini Flash
  - Single GPT-4: P99 = 5000ms, Cost = $0.03
  - Multi-level: P99 = 800ms (84% reduction), Expected cost = $0.0215 (28% savings)

  ## Tier Configuration

  Each tier should specify:
  - `:name` - Identifier for the tier
  - `:delay_ms` - How long to wait before escalating to next tier
  - `:request_fn` - Function to execute for this tier
  - `:quality_threshold` - Minimum quality score (optional)
  - `:cost` - Cost per request (optional, for tracking)

  ## Example

      tiers = [
        %{
          name: :primary_gpt4,
          delay_ms: 500,
          quality_threshold: 0.95,
          request_fn: fn -> ReqLLM.chat_completion(model: "gpt-4", ...) end,
          cost: 0.03
        },
        %{
          name: :backup_gpt35,
          delay_ms: 300,
          quality_threshold: 0.85,
          request_fn: fn -> ReqLLM.chat_completion(model: "gpt-3.5-turbo", ...) end,
          cost: 0.002
        },
        %{
          name: :fallback_gemini,
          delay_ms: 0,
          quality_threshold: 0.0,
          request_fn: fn -> ReqLLM.chat_completion(model: "gemini-flash", ...) end,
          cost: 0.0001
        }
      ]

      {:ok, result, metadata} = CrucibleHedging.MultiLevel.execute(tiers)
  """

  require Logger

  @type tier :: %{
          name: atom(),
          delay_ms: non_neg_integer(),
          request_fn: (-> any()),
          quality_threshold: float() | nil,
          cost: float() | nil
        }

  @type metadata :: %{
          tier: atom(),
          hedges_fired: non_neg_integer(),
          total_latency: non_neg_integer(),
          total_cost: float(),
          all_results: map()
        }

  @type result :: {:ok, any(), metadata()} | {:error, any()}

  defstruct [
    :tiers,
    :current_tier,
    :started_at,
    :results,
    :tasks,
    :telemetry_prefix
  ]

  @doc """
  Executes multi-tier hedging.

  Starts with the first tier and progressively escalates to subsequent tiers
  if previous tiers don't complete within their delay threshold.

  Returns the first result that meets quality requirements, or the best
  available result if all tiers complete.
  """
  @spec execute([tier()], keyword()) :: result()
  def execute(tiers, opts \\ []) when is_list(tiers) and tiers != [] do
    telemetry_prefix = Keyword.get(opts, :telemetry_prefix, [:crucible_hedging, :multi_level])
    request_id = make_ref()

    :telemetry.execute(
      telemetry_prefix ++ [:start],
      %{tier_count: length(tiers)},
      %{request_id: request_id}
    )

    state = %__MODULE__{
      tiers: tiers,
      current_tier: 0,
      started_at: System.monotonic_time(:millisecond),
      results: %{},
      tasks: %{},
      telemetry_prefix: telemetry_prefix
    }

    try do
      result = execute_tier(state, opts)

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - state.started_at

      case result do
        {:ok, _value, metadata} ->
          :telemetry.execute(
            telemetry_prefix ++ [:stop],
            %{duration: duration},
            Map.merge(metadata, %{request_id: request_id})
          )

          result

        error ->
          :telemetry.execute(
            telemetry_prefix ++ [:exception],
            %{duration: duration},
            %{request_id: request_id}
          )

          error
      end
    rescue
      error ->
        Logger.error("Multi-level hedging failed: #{inspect(error)}")
        {:error, error}
    end
  end

  # Private Functions

  defp execute_tier(%{current_tier: tier_idx, tiers: tiers} = state, _opts)
       when tier_idx >= length(tiers) do
    # All tiers exhausted, return best result
    case select_best_result(state) do
      {:ok, result, tier_name} ->
        total_latency = System.monotonic_time(:millisecond) - state.started_at
        total_cost = calculate_total_cost(state)

        {:ok, result,
         %{
           tier: tier_name,
           hedges_fired: tier_idx - 1,
           total_latency: total_latency,
           total_cost: total_cost,
           all_results: state.results
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp execute_tier(state, opts) do
    tier_config = Enum.at(state.tiers, state.current_tier)

    # Emit tier start event
    :telemetry.execute(
      state.telemetry_prefix ++ [:tier, :start],
      %{tier_index: state.current_tier},
      %{tier_name: tier_config.name}
    )

    # Start current tier request
    task =
      Task.async(fn ->
        tier_start = System.monotonic_time(:millisecond)

        try do
          result = tier_config.request_fn.()
          latency = System.monotonic_time(:millisecond) - tier_start
          {:ok, result, latency}
        rescue
          error ->
            {:error, error}
        end
      end)

    # Store task for potential cancellation
    tasks = Map.put(state.tasks, tier_config.name, task)
    state = %{state | tasks: tasks}

    # Wait for tier delay or completion
    case Task.yield(task, tier_config.delay_ms) do
      {:ok, {:ok, result, latency}} ->
        # Tier completed, check quality
        :telemetry.execute(
          state.telemetry_prefix ++ [:tier, :completed],
          %{latency: latency},
          %{tier_name: tier_config.name}
        )

        if meets_quality_threshold?(result, tier_config[:quality_threshold]) do
          # Quality acceptable, use this result
          cancel_remaining_tasks(state, tier_config.name)
          total_latency = System.monotonic_time(:millisecond) - state.started_at

          {:ok, result,
           %{
             tier: tier_config.name,
             hedges_fired: state.current_tier,
             total_latency: total_latency,
             total_cost: calculate_cost_up_to_tier(state, state.current_tier),
             all_results: %{tier_config.name => {:ok, result}}
           }}
        else
          # Quality insufficient, try next tier
          state = %{
            state
            | results: Map.put(state.results, tier_config.name, {:ok, result, latency}),
              current_tier: state.current_tier + 1
          }

          execute_tier(state, opts)
        end

      {:ok, {:error, reason}} ->
        # Tier failed, try next tier
        Logger.warning("Tier #{tier_config.name} failed: #{inspect(reason)}")

        state = %{
          state
          | results: Map.put(state.results, tier_config.name, {:error, reason}),
            current_tier: state.current_tier + 1
        }

        execute_tier(state, opts)

      nil ->
        # Tier still running, escalate to next tier
        :telemetry.execute(
          state.telemetry_prefix ++ [:tier, :timeout],
          %{delay: tier_config.delay_ms},
          %{tier_name: tier_config.name}
        )

        state = %{
          state
          | results: Map.put(state.results, tier_config.name, {:pending, task}),
            current_tier: state.current_tier + 1
        }

        execute_tier(state, opts)
    end
  end

  defp meets_quality_threshold?(_result, nil), do: true

  defp meets_quality_threshold?(result, threshold) when is_map(result) do
    # Check if result has a quality/confidence score
    confidence = Map.get(result, :confidence) || Map.get(result, :quality_score) || 1.0
    confidence >= threshold
  end

  defp meets_quality_threshold?(_result, _threshold), do: true

  defp select_best_result(state) do
    # First, wait for any pending tasks with a short timeout
    state = wait_for_pending_tasks(state, 100)

    # Find the best completed result that meets quality threshold
    state.results
    |> Enum.filter(fn
      {tier_name, {:ok, result, _latency}} ->
        # Check if this result meets its tier's quality threshold
        tier_config = Enum.find(state.tiers, fn t -> t.name == tier_name end)
        meets_quality_threshold?(result, tier_config[:quality_threshold])

      _ ->
        false
    end)
    |> case do
      [] ->
        # No results meet quality threshold, return best available
        state.results
        |> Enum.find_value(fn
          {tier_name, {:ok, result, _latency}} -> {:ok, result, tier_name}
          _ -> nil
        end)
        |> case do
          nil -> {:error, :all_tiers_failed}
          result -> result
        end

      completed_results ->
        # Return the first successful result that meets quality (prefer earlier tiers)
        {tier_name, {:ok, result, _latency}} = List.first(completed_results)
        {:ok, result, tier_name}
    end
  end

  defp wait_for_pending_tasks(state, timeout) do
    pending_tasks =
      state.results
      |> Enum.filter(fn
        {_tier, {:pending, _task}} -> true
        _ -> false
      end)
      |> Enum.map(fn {tier, {:pending, task}} -> {tier, task} end)

    if Enum.empty?(pending_tasks) do
      state
    else
      tasks = Enum.map(pending_tasks, fn {_tier, task} -> task end)
      results = Task.yield_many(tasks, timeout)

      # Update results with completed tasks
      updated_results =
        Enum.reduce(Enum.zip(pending_tasks, results), state.results, &update_pending_result/2)

      %{state | results: updated_results}
    end
  end

  defp update_pending_result({{tier, _task}, {_yielded_task, task_result}}, acc) do
    case task_result do
      {:ok, {:ok, result, latency}} ->
        Map.put(acc, tier, {:ok, result, latency})

      {:ok, {:error, reason}} ->
        Map.put(acc, tier, {:error, reason})

      nil ->
        # Still pending
        acc
    end
  end

  defp cancel_remaining_tasks(state, winner_tier) do
    state.tasks
    |> Enum.each(fn {tier_name, task} ->
      if tier_name != winner_tier do
        Task.shutdown(task, :brutal_kill)

        :telemetry.execute(
          state.telemetry_prefix ++ [:tier, :cancelled],
          %{},
          %{tier_name: tier_name}
        )
      end
    end)
  end

  defp calculate_total_cost(state) do
    state.results
    |> Enum.reduce(0.0, fn {tier_name, result}, acc ->
      tier = Enum.find(state.tiers, fn t -> t.name == tier_name end)
      cost = tier[:cost] || 0.0

      case result do
        {:ok, _result, _latency} -> acc + cost
        {:pending, _task} -> acc + cost
        {:error, _reason} -> acc
      end
    end)
  end

  defp calculate_cost_up_to_tier(state, tier_idx) do
    state.tiers
    |> Enum.take(tier_idx + 1)
    |> Enum.reduce(0.0, fn tier, acc ->
      cost = tier[:cost] || 0.0
      acc + cost
    end)
  end
end
