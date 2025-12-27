defmodule CrucibleHedging.CrucibleStage do
  @moduledoc """
  Crucible.Stage implementation for request hedging.

  This stage wraps CrucibleHedging for use in crucible_framework pipelines.
  It reads hedging configuration from the experiment IR and stores results
  in the context artifacts and metrics.

  ## Context Requirements

  Expects the context to have:
  - `context.experiment.reliability.hedging` - `%CrucibleIR.Reliability.Hedging{}`

  The stage also requires a request function to be provided via options:
  - `opts[:request_fn]` - A 0-arity function to execute with hedging

  ## Outputs

  On success, the stage:
  - Stores hedging result in `context.artifacts[:hedging_result]`
  - Merges hedging metadata into `context.metrics[:hedging]`
  - Marks `:hedging` stage as complete

  ## Usage

      # In pipeline configuration
      stages: [
        {CrucibleHedging.CrucibleStage, request_fn: fn -> api_call() end}
      ]

  ## Example

      experiment = %CrucibleIR.Experiment{
        id: "my-experiment",
        backend: %BackendRef{id: :openai},
        reliability: %Reliability{
          hedging: %CrucibleIR.Reliability.Hedging{
            strategy: :percentile,
            percentile: 95,
            max_hedges: 1
          }
        }
      }

      ctx = %Crucible.Context{
        experiment_id: experiment.id,
        run_id: "run-1",
        experiment: experiment
      }

      {:ok, updated_ctx} = CrucibleHedging.CrucibleStage.run(ctx, %{
        request_fn: fn -> make_api_call() end
      })

      result = Crucible.Context.get_artifact(updated_ctx, :hedging_result)
      metadata = Crucible.Context.get_metric(updated_ctx, :hedging)
  """

  @behaviour Crucible.Stage

  alias Crucible.Context
  alias CrucibleIR.Reliability.Hedging

  require Logger

  @valid_strategies [:off, :fixed, :percentile, :adaptive, :workload_aware, :exponential_backoff]

  @doc """
  Runs the hedging stage on the provided context.

  ## Parameters

  - `ctx` - A `%Crucible.Context{}` struct containing experiment configuration
  - `opts` - A map with `:request_fn` (required) - a 0-arity function to execute

  ## Returns

  - `{:ok, %Crucible.Context{}}` on success with hedging results stored
  - `{:error, term()}` on failure

  ## Examples

      iex> ctx = create_context(%Hedging{strategy: :off})
      iex> opts = %{request_fn: fn -> :result end}
      iex> {:ok, updated_ctx} = CrucibleHedging.CrucibleStage.run(ctx, opts)
      iex> Crucible.Context.get_artifact(updated_ctx, :hedging_result)
      :result
  """
  @impl Crucible.Stage
  @spec run(Context.t(), map()) :: {:ok, Context.t()} | {:error, term()}
  def run(%Context{experiment: experiment} = ctx, opts) do
    with {:ok, hedging_config} <- extract_hedging_config(experiment),
         {:ok, request_fn} <- extract_request_fn(opts),
         {:ok, strategy} <- validate_strategy(hedging_config.strategy) do
      execute_hedging(ctx, hedging_config, request_fn, strategy)
    end
  end

  @doc """
  Describes the hedging stage for documentation and introspection.

  Returns the canonical schema format for stage introspection, validation, and tooling.

  ## Parameters

  - `opts` - Optional configuration map (unused in canonical format)

  ## Returns

  A map with canonical schema keys:
  - `:__schema_version__` - Schema version for compatibility
  - `:name` - Stage name as atom
  - `:description` - Human-readable description
  - `:required` - List of required option keys
  - `:optional` - List of optional option keys
  - `:types` - Type specifications for options
  - `:defaults` - Default values for optional options
  - `:__extensions__` - Domain-specific metadata
  """
  @impl Crucible.Stage
  @spec describe(map()) :: map()
  def describe(_opts) do
    %{
      __schema_version__: "1.0.0",
      name: :hedging,
      description: "Request hedging for tail latency reduction",
      required: [:request_fn],
      optional: [:strategy, :delay_ms, :percentile, :max_hedges, :timeout_ms],
      types: %{
        request_fn: {:function, 0},
        strategy:
          {:enum, [:off, :fixed, :percentile, :adaptive, :workload_aware, :exponential_backoff]},
        delay_ms: :integer,
        percentile: :float,
        max_hedges: :integer,
        timeout_ms: :integer
      },
      defaults: %{
        strategy: :off,
        delay_ms: 100,
        max_hedges: 2,
        timeout_ms: 30_000
      },
      __extensions__: %{
        hedging: %{
          config_type: CrucibleIR.Reliability.Hedging,
          inputs: [
            %{
              name: :experiment,
              path: [:experiment, :reliability, :hedging],
              type: :struct,
              struct_module: CrucibleIR.Reliability.Hedging,
              required: true,
              description: "Hedging configuration from experiment IR"
            },
            %{
              name: :request_fn,
              path: [:request_fn],
              type: :function,
              arity: 0,
              required: true,
              description: "Function to execute with hedging"
            }
          ],
          outputs: [
            %{
              name: :hedging_result,
              location: :artifacts,
              type: :any,
              description: "Result from the request function"
            },
            %{
              name: :hedging,
              location: :metrics,
              type: :map,
              description: "Hedging execution metadata (latency, hedge stats, etc.)"
            }
          ]
        }
      }
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  @spec extract_hedging_config(CrucibleIR.Experiment.t()) ::
          {:ok, Hedging.t()}
          | {:error, :missing_hedging_config | {:invalid_hedging_config, any()}}
  defp extract_hedging_config(experiment) do
    case get_in_safe(experiment, [:reliability, :hedging]) do
      %Hedging{} = config ->
        {:ok, config}

      nil ->
        {:error, :missing_hedging_config}

      other ->
        {:error, {:invalid_hedging_config, other}}
    end
  end

  @spec extract_request_fn(map()) ::
          {:ok, (-> any())} | {:error, :missing_request_fn | {:invalid_request_fn, any()}}
  defp extract_request_fn(opts) do
    case Map.get(opts, :request_fn) do
      fn_val when is_function(fn_val, 0) ->
        {:ok, fn_val}

      nil ->
        {:error, :missing_request_fn}

      other ->
        {:error, {:invalid_request_fn, other}}
    end
  end

  @spec validate_strategy(atom()) :: {:ok, atom()} | {:error, {:invalid_strategy, atom()}}
  defp validate_strategy(strategy) when strategy in @valid_strategies do
    {:ok, strategy}
  end

  defp validate_strategy(strategy) do
    {:error, {:invalid_strategy, strategy}}
  end

  @spec execute_hedging(Context.t(), Hedging.t(), (-> any()), atom()) ::
          {:ok, Context.t()} | {:error, term()}
  defp execute_hedging(ctx, _hedging_config, request_fn, :off) do
    execute_without_hedging(ctx, request_fn)
  end

  defp execute_hedging(ctx, hedging_config, request_fn, _strategy) do
    execute_with_hedging(ctx, hedging_config, request_fn)
  end

  @spec execute_without_hedging(Context.t(), (-> any())) ::
          {:ok, Context.t()} | {:error, {:request_failed, any()}}
  defp execute_without_hedging(ctx, request_fn) do
    start_time = System.monotonic_time(:millisecond)

    try do
      result = request_fn.()
      end_time = System.monotonic_time(:millisecond)
      latency = end_time - start_time

      metadata = %{
        hedged: false,
        hedge_won: false,
        total_latency: latency,
        primary_latency: latency,
        backup_latency: nil,
        hedge_delay: nil,
        cost: 1.0,
        strategy: :off
      }

      updated_ctx =
        ctx
        |> Context.put_artifact(:hedging_result, result)
        |> Context.put_metric(:hedging, metadata)
        |> Context.mark_stage_complete(:hedging)

      {:ok, updated_ctx}
    rescue
      error ->
        Logger.error("Request execution failed: #{inspect(error)}")
        {:error, {:request_failed, error}}
    end
  end

  @spec execute_with_hedging(Context.t(), Hedging.t(), (-> any())) ::
          {:ok, Context.t()} | {:error, term()}
  defp execute_with_hedging(ctx, hedging_config, request_fn) do
    hedging_opts = build_hedging_opts(hedging_config)

    try do
      case CrucibleHedging.request(request_fn, hedging_opts) do
        {:ok, result, metadata} ->
          hedging_metadata = Map.put(metadata, :strategy, hedging_config.strategy)

          updated_ctx =
            ctx
            |> Context.put_artifact(:hedging_result, result)
            |> Context.put_metric(:hedging, hedging_metadata)
            |> Context.mark_stage_complete(:hedging)

          {:ok, updated_ctx}

        {:error, reason} ->
          Logger.error("Hedging request failed: #{inspect(reason)}")
          {:error, {:hedging_failed, reason}}
      end
    rescue
      error ->
        Logger.error("Hedging execution failed: #{inspect(error)}")
        {:error, {:hedging_execution_failed, error}}
    end
  end

  @spec build_hedging_opts(Hedging.t()) :: keyword()
  defp build_hedging_opts(%Hedging{} = config) do
    base_opts = [
      strategy: config.strategy,
      telemetry_prefix: [:crucible_hedging, :crucible_stage]
    ]

    strategy_opts =
      case config.strategy do
        :fixed ->
          maybe_add_opt([], :delay_ms, config.delay_ms)

        :percentile ->
          maybe_add_opt([], :percentile, config.percentile)

        :adaptive ->
          extract_adaptive_opts(config.options)

        :workload_aware ->
          extract_workload_opts(config.options)

        :exponential_backoff ->
          extract_exponential_opts(config.options)

        _ ->
          []
      end

    general_opts = maybe_add_opt([], :max_hedges, config.max_hedges)

    base_opts
    |> Keyword.merge(strategy_opts)
    |> Keyword.merge(general_opts)
  end

  @spec extract_adaptive_opts(map() | nil) :: keyword()
  defp extract_adaptive_opts(nil), do: []

  defp extract_adaptive_opts(options) when is_map(options) do
    []
    |> maybe_add_opt(:delay_candidates, Map.get(options, "delay_candidates"))
    |> maybe_add_opt(:learning_rate, Map.get(options, "learning_rate"))
  end

  @spec extract_workload_opts(map() | nil) :: keyword()
  defp extract_workload_opts(nil), do: []

  defp extract_workload_opts(options) when is_map(options) do
    []
    |> maybe_add_opt(:base_delay, Map.get(options, "base_delay"))
    |> maybe_add_opt(:prompt_length, Map.get(options, "prompt_length"))
    |> maybe_add_opt(:model_complexity, parse_atom(Map.get(options, "model_complexity")))
    |> maybe_add_opt(:time_of_day, parse_atom(Map.get(options, "time_of_day")))
    |> maybe_add_opt(:priority, parse_atom(Map.get(options, "priority")))
  end

  @spec extract_exponential_opts(map() | nil) :: keyword()
  defp extract_exponential_opts(nil), do: []

  defp extract_exponential_opts(options) when is_map(options) do
    []
    |> maybe_add_opt(:exponential_base_delay, Map.get(options, "exponential_base_delay"))
    |> maybe_add_opt(:exponential_min_delay, Map.get(options, "exponential_min_delay"))
    |> maybe_add_opt(:exponential_max_delay, Map.get(options, "exponential_max_delay"))
    |> maybe_add_opt(
      :exponential_increase_factor,
      Map.get(options, "exponential_increase_factor")
    )
    |> maybe_add_opt(
      :exponential_decrease_factor,
      Map.get(options, "exponential_decrease_factor")
    )
    |> maybe_add_opt(:exponential_error_factor, Map.get(options, "exponential_error_factor"))
  end

  @spec maybe_add_opt(keyword(), atom(), any()) :: keyword()
  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @spec parse_atom(any()) :: atom() | nil
  defp parse_atom(nil), do: nil
  defp parse_atom(value) when is_atom(value), do: value

  defp parse_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp parse_atom(_), do: nil

  # Safe get_in that handles structs properly
  @spec get_in_safe(struct() | map(), [atom()]) :: any()
  defp get_in_safe(data, []), do: data

  defp get_in_safe(data, [key | rest]) when is_struct(data) do
    case Map.get(data, key) do
      nil -> nil
      value -> get_in_safe(value, rest)
    end
  end

  defp get_in_safe(data, [key | rest]) when is_map(data) do
    case Map.get(data, key) do
      nil -> nil
      value -> get_in_safe(value, rest)
    end
  end

  defp get_in_safe(_, _), do: nil
end
