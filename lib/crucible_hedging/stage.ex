defmodule CrucibleHedging.Stage do
  @moduledoc """
  Pipeline stage for request hedging to reduce tail latency.

  This module implements the stage interface for use in Crucible pipeline
  processing. It uses hedging configuration from `CrucibleIR.Reliability.Hedging`
  to apply request hedging to reduce tail latency.

  ## Context Requirements

  The stage expects the following context structure:

      %{
        experiment: %{
          reliability: %{
            hedging: %CrucibleIR.Reliability.Hedging{
              strategy: :fixed | :percentile | :adaptive | :workload_aware | :exponential_backoff,
              delay_ms: integer(),
              percentile: float(),
              max_hedges: integer(),
              budget_percent: float(),
              options: map()
            }
          }
        },
        request_fn: function(),
        # ... other context fields
      }

  ## Usage

  The stage can be used in a pipeline:

      config = %CrucibleIR.Reliability.Hedging{
        strategy: :percentile,
        percentile: 95,
        max_hedges: 1,
        budget_percent: 10.0
      }

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> make_api_call() end
      }

      {:ok, updated_context} = CrucibleHedging.Stage.run(context)

  ## Options

  The `run/2` function accepts optional configuration overrides:

  - `:strategy` - Override strategy from IR config
  - `:delay_ms` - Override delay_ms from IR config
  - `:percentile` - Override percentile from IR config
  - `:max_hedges` - Override max_hedges from IR config
  - `:timeout_ms` - Request timeout (default: 30_000)
  - `:enable_cancellation` - Cancel slower requests (default: true)
  - `:telemetry_prefix` - Telemetry prefix (default: [:crucible_hedging, :stage])
  """

  alias CrucibleIR.Reliability.Hedging
  require Logger

  @type context :: map()
  @type opts :: keyword()
  @type result :: {:ok, context()} | {:error, term()}

  @doc """
  Runs the hedging stage on the provided context.

  ## Parameters

  - `context` - Pipeline context containing experiment configuration and request function
  - `opts` - Optional configuration overrides (keyword list)

  ## Returns

  - `{:ok, updated_context}` with hedging results in the context
  - `{:error, reason}` if hedging fails

  ## Examples

      iex> config = %CrucibleIR.Reliability.Hedging{strategy: :off}
      iex> context = %{experiment: %{reliability: %{hedging: config}}, request_fn: fn -> :ok end}
      iex> {:ok, result} = CrucibleHedging.Stage.run(context)
      iex> result.result
      :ok

      iex> config = %CrucibleIR.Reliability.Hedging{strategy: :fixed, delay_ms: 100}
      iex> context = %{experiment: %{reliability: %{hedging: config}}, request_fn: fn -> :result end}
      iex> {:ok, result} = CrucibleHedging.Stage.run(context)
      iex> result.result
      :result
      iex> is_map(result.hedging_metadata)
      true
  """
  @spec run(context(), opts()) :: result()
  def run(context, opts \\ []) do
    with {:ok, hedging_config} <- extract_hedging_config(context),
         {:ok, request_fn} <- extract_request_fn(context) do
      case hedging_config.strategy do
        :off ->
          # No hedging - just execute the request
          execute_without_hedging(context, request_fn)

        strategy
        when strategy in [:fixed, :percentile, :adaptive, :workload_aware, :exponential_backoff] ->
          # Execute with hedging
          execute_with_hedging(context, hedging_config, request_fn, opts)

        other ->
          {:error, {:invalid_strategy, other}}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Describes the stage for documentation and introspection.

  ## Parameters

  - `opts` - Optional configuration (keyword list)

  ## Returns

  A map describing the stage:

  - `:name` - Stage name
  - `:description` - Stage description
  - `:inputs` - Required input fields
  - `:outputs` - Output fields added to context
  - `:config_schema` - Configuration schema

  ## Examples

      iex> description = CrucibleHedging.Stage.describe()
      iex> description.name
      :hedging
      iex> description.description
      "Request hedging to reduce tail latency"
  """
  @spec describe(opts()) :: map()
  def describe(_opts \\ []) do
    %{
      name: :hedging,
      description: "Request hedging to reduce tail latency",
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
          name: :result,
          path: [:result],
          type: :any,
          description: "Result from the request function"
        },
        %{
          name: :hedging_metadata,
          path: [:hedging_metadata],
          type: :map,
          description: "Hedging execution metadata (latency, hedge stats, etc.)"
        }
      ],
      config_schema: [
        %{name: :strategy, type: :atom, description: "Override hedging strategy"},
        %{name: :delay_ms, type: :integer, description: "Override hedge delay"},
        %{name: :percentile, type: :float, description: "Override percentile target"},
        %{name: :max_hedges, type: :integer, description: "Override max hedge count"},
        %{name: :timeout_ms, type: :integer, description: "Request timeout", default: 30_000},
        %{
          name: :enable_cancellation,
          type: :boolean,
          description: "Cancel slower requests",
          default: true
        },
        %{
          name: :telemetry_prefix,
          type: {:list, :atom},
          description: "Telemetry event prefix",
          default: [:crucible_hedging, :stage]
        }
      ]
    }
  end

  # Private Functions

  defp extract_hedging_config(context) do
    case get_in(context, [:experiment, :reliability, :hedging]) do
      %Hedging{} = config ->
        {:ok, config}

      nil ->
        {:error, :missing_hedging_config}

      other ->
        {:error, {:invalid_hedging_config, other}}
    end
  end

  defp extract_request_fn(context) do
    case Map.get(context, :request_fn) do
      fn_val when is_function(fn_val, 0) ->
        {:ok, fn_val}

      nil ->
        {:error, :missing_request_fn}

      other ->
        {:error, {:invalid_request_fn, other}}
    end
  end

  defp execute_without_hedging(context, request_fn) do
    start_time = System.monotonic_time(:millisecond)
    result = request_fn.()
    end_time = System.monotonic_time(:millisecond)
    latency = end_time - start_time

    updated_context =
      context
      |> Map.put(:result, result)
      |> Map.put(:hedging_metadata, %{
        hedged: false,
        hedge_won: false,
        total_latency: latency,
        primary_latency: latency,
        backup_latency: nil,
        hedge_delay: nil,
        cost: 1.0,
        strategy: :off
      })

    {:ok, updated_context}
  rescue
    error ->
      Logger.error("Request execution failed: #{inspect(error)}")
      {:error, {:request_failed, error}}
  end

  defp execute_with_hedging(context, hedging_config, request_fn, opts) do
    # Build hedging options from IR config and opts
    hedging_opts = build_hedging_opts(hedging_config, opts)

    try do
      case CrucibleHedging.request(request_fn, hedging_opts) do
        {:ok, result, metadata} ->
          updated_context =
            context
            |> Map.put(:result, result)
            |> Map.put(:hedging_metadata, Map.put(metadata, :strategy, hedging_config.strategy))

          {:ok, updated_context}

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

  defp build_hedging_opts(%Hedging{} = config, opts) do
    base_opts = [
      strategy: config.strategy,
      telemetry_prefix: Keyword.get(opts, :telemetry_prefix, [:crucible_hedging, :stage])
    ]

    # Add strategy-specific options from IR config
    strategy_opts =
      case config.strategy do
        :fixed ->
          if config.delay_ms, do: [delay_ms: config.delay_ms], else: []

        :percentile ->
          if config.percentile, do: [percentile: config.percentile], else: []

        :adaptive ->
          # Extract adaptive-specific options from config.options if present
          extract_adaptive_opts(config.options)

        :workload_aware ->
          # Extract workload-aware options from config.options if present
          extract_workload_opts(config.options)

        :exponential_backoff ->
          # Extract exponential backoff options from config.options if present
          extract_exponential_opts(config.options)

        _ ->
          []
      end

    # Add general hedging options
    general_opts =
      []
      |> maybe_add(:max_hedges, config.max_hedges)
      |> maybe_add(:timeout_ms, Keyword.get(opts, :timeout_ms))
      |> maybe_add(:enable_cancellation, Keyword.get(opts, :enable_cancellation))

    # Merge all options, with opts taking precedence
    base_opts
    |> Keyword.merge(strategy_opts)
    |> Keyword.merge(general_opts)
    |> Keyword.merge(opts)
  end

  defp extract_adaptive_opts(nil), do: []

  defp extract_adaptive_opts(options) when is_map(options) do
    []
    |> maybe_add(:delay_candidates, Map.get(options, "delay_candidates"))
    |> maybe_add(:learning_rate, Map.get(options, "learning_rate"))
  end

  defp extract_workload_opts(nil), do: []

  defp extract_workload_opts(options) when is_map(options) do
    []
    |> maybe_add(:base_delay, Map.get(options, "base_delay"))
    |> maybe_add(:prompt_length, Map.get(options, "prompt_length"))
    |> maybe_add(:model_complexity, parse_atom(Map.get(options, "model_complexity")))
    |> maybe_add(:time_of_day, parse_atom(Map.get(options, "time_of_day")))
    |> maybe_add(:priority, parse_atom(Map.get(options, "priority")))
  end

  defp extract_exponential_opts(nil), do: []

  defp extract_exponential_opts(options) when is_map(options) do
    []
    |> maybe_add(:exponential_base_delay, Map.get(options, "exponential_base_delay"))
    |> maybe_add(:exponential_min_delay, Map.get(options, "exponential_min_delay"))
    |> maybe_add(:exponential_max_delay, Map.get(options, "exponential_max_delay"))
    |> maybe_add(:exponential_increase_factor, Map.get(options, "exponential_increase_factor"))
    |> maybe_add(:exponential_decrease_factor, Map.get(options, "exponential_decrease_factor"))
    |> maybe_add(:exponential_error_factor, Map.get(options, "exponential_error_factor"))
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_atom(nil), do: nil
  defp parse_atom(value) when is_atom(value), do: value

  defp parse_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp parse_atom(_), do: nil
end
