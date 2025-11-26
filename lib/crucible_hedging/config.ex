defmodule CrucibleHedging.Config do
  @moduledoc """
  Configuration validation and schema for hedging options.

  This module provides compile-time validation of hedging configuration
  using NimbleOptions.

  ## Schema

  - `:strategy` - Strategy to use (`:fixed`, `:percentile`, `:adaptive`, `:workload_aware`, `:exponential_backoff`)
  - `:delay_ms` - Fixed delay in milliseconds (for `:fixed` strategy)
  - `:percentile` - Target percentile (for `:percentile` strategy, default: 95)
  - `:max_hedges` - Maximum number of backup requests (default: 1)
  - `:timeout_ms` - Total request timeout (default: 30_000)
  - `:enable_cancellation` - Cancel slower requests (default: true)
  - `:telemetry_prefix` - Telemetry event prefix (default: `[:crucible_hedging]`)
  - `:strategy_name` - Optional process name for isolating state per backend

  ## Strategy-specific Options

  ### Fixed Strategy
  - `:delay_ms` - Fixed delay before hedging (required)

  ### Percentile Strategy
  - `:percentile` - Target percentile (50-99, default: 95)
  - `:window_size` - Rolling window size (default: 1000)
  - `:initial_delay` - Initial delay before warmup (default: 100)

  ### Adaptive Strategy
  - `:delay_candidates` - List of delay values to try (default: [50, 100, 200, 500, 1000])
  - `:learning_rate` - Learning rate for updates (default: 0.1)

  ### Workload-Aware Strategy
  - `:base_delay` - Base delay in milliseconds (default: 100)
  - `:prompt_length` - Length of prompt/payload
  - `:model_complexity` - `:simple`, `:medium`, or `:complex`
  - `:time_of_day` - `:peak`, `:normal`, or `:off_peak`

  ### Exponential Backoff Strategy
  - `:exponential_base_delay` - Initial delay (default: 100)
  - `:exponential_min_delay` - Minimum delay floor (default: 10)
  - `:exponential_max_delay` - Maximum delay ceiling (default: 5000)
  - `:exponential_increase_factor` - Failure multiplier (default: 1.5)
  - `:exponential_decrease_factor` - Success multiplier (default: 0.9)
  - `:exponential_error_factor` - Error multiplier (default: 2.0)

  ## Example

      config = CrucibleHedging.Config.validate!([
        strategy: :percentile,
        percentile: 95,
        timeout_ms: 10_000
      ])
  """

  @schema NimbleOptions.new!(
            strategy: [
              type:
                {:in, [:fixed, :percentile, :adaptive, :workload_aware, :exponential_backoff]},
              default: :percentile,
              doc: "Hedging strategy to use"
            ],
            strategy_name: [
              type: :atom,
              doc:
                "Optional registered name for strategy process (useful for per-backend isolation)"
            ],
            delay_ms: [
              type: :non_neg_integer,
              doc: "Fixed delay in milliseconds (for :fixed strategy)"
            ],
            percentile: [
              type: :non_neg_integer,
              default: 95,
              doc: "Target percentile for :percentile strategy (50-99)"
            ],
            window_size: [
              type: :pos_integer,
              default: 1000,
              doc: "Rolling window size for :percentile strategy"
            ],
            initial_delay: [
              type: :non_neg_integer,
              default: 100,
              doc: "Initial delay before warmup for :percentile strategy"
            ],
            delay_candidates: [
              type: {:list, :non_neg_integer},
              default: [50, 100, 200, 500, 1000],
              doc: "Delay candidates for :adaptive strategy"
            ],
            learning_rate: [
              type: :float,
              default: 0.1,
              doc: "Learning rate for :adaptive strategy (0.0-1.0)"
            ],
            base_delay: [
              type: :non_neg_integer,
              default: 100,
              doc: "Base delay for :workload_aware strategy"
            ],
            prompt_length: [
              type: :non_neg_integer,
              doc: "Prompt length for :workload_aware strategy"
            ],
            model_complexity: [
              type: {:in, [:simple, :medium, :complex]},
              doc: "Model complexity for :workload_aware strategy"
            ],
            time_of_day: [
              type: {:in, [:peak, :normal, :off_peak]},
              doc: "Time of day for :workload_aware strategy"
            ],
            priority: [
              type: {:in, [:low, :normal, :high]},
              doc: "Request priority for :workload_aware strategy"
            ],
            exponential_min_delay: [
              type: :non_neg_integer,
              default: 10,
              doc: "Minimum delay for :exponential_backoff strategy"
            ],
            exponential_max_delay: [
              type: :non_neg_integer,
              default: 5000,
              doc: "Maximum delay for :exponential_backoff strategy"
            ],
            exponential_base_delay: [
              type: :non_neg_integer,
              default: 100,
              doc: "Initial delay for :exponential_backoff strategy"
            ],
            exponential_increase_factor: [
              type: :float,
              default: 1.5,
              doc: "Failure increase factor for :exponential_backoff strategy"
            ],
            exponential_decrease_factor: [
              type: :float,
              default: 0.9,
              doc: "Success decrease factor for :exponential_backoff strategy"
            ],
            exponential_error_factor: [
              type: :float,
              default: 2.0,
              doc: "Error increase factor for :exponential_backoff strategy"
            ],
            max_hedges: [
              type: :pos_integer,
              default: 1,
              doc: "Maximum number of backup requests (1-4)"
            ],
            timeout_ms: [
              type: :pos_integer,
              default: 30_000,
              doc: "Total request timeout in milliseconds"
            ],
            enable_cancellation: [
              type: :boolean,
              default: true,
              doc: "Whether to cancel slower requests"
            ],
            telemetry_prefix: [
              type: {:list, :atom},
              default: [:crucible_hedging],
              doc: "Telemetry event prefix"
            ]
          )

  @doc """
  Validates hedging configuration options.

  Returns `{:ok, validated_opts}` or `{:error, validation_error}`.

  ## Examples

      iex> {:ok, config} = CrucibleHedging.Config.validate(strategy: :percentile, percentile: 95)
      iex> config[:strategy]
      :percentile
      iex> config[:percentile]
      95

      iex> {:ok, config} = CrucibleHedging.Config.validate(strategy: :fixed, delay_ms: 200)
      iex> config[:strategy]
      :fixed
      iex> config[:delay_ms]
      200

      iex> match?({:error, _}, CrucibleHedging.Config.validate(strategy: :invalid))
      true
  """
  @spec validate(keyword()) :: {:ok, keyword()} | {:error, NimbleOptions.ValidationError.t()}
  def validate(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, validated} ->
        # Additional validation based on strategy
        case validate_strategy_specific(validated) do
          :ok -> {:ok, validated}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Validates hedging configuration options, raising on error.

  ## Examples

      iex> config = CrucibleHedging.Config.validate!(strategy: :percentile, percentile: 95)
      iex> config[:strategy]
      :percentile

      iex> config = CrucibleHedging.Config.validate!(strategy: :workload_aware, base_delay: 150)
      iex> config[:base_delay]
      150
  """
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) when is_list(opts) do
    case validate(opts) do
      {:ok, validated} -> validated
      {:error, error} -> raise error
    end
  end

  # Private Functions

  defp validate_strategy_specific(opts) do
    strategy = Keyword.get(opts, :strategy)

    case strategy do
      :fixed ->
        validate_fixed_strategy(opts)

      :percentile ->
        validate_percentile_strategy(opts)

      :adaptive ->
        validate_adaptive_strategy(opts)

      :workload_aware ->
        validate_workload_aware_strategy(opts)

      :exponential_backoff ->
        validate_exponential_backoff_strategy(opts)

      _ ->
        :ok
    end
  end

  defp validate_fixed_strategy(opts) do
    delay_ms = Keyword.get(opts, :delay_ms)

    if delay_ms == nil do
      {:error,
       %ArgumentError{message: ":fixed strategy requires :delay_ms option to be specified"}}
    else
      :ok
    end
  end

  defp validate_percentile_strategy(opts) do
    percentile = Keyword.get(opts, :percentile, 95)

    if percentile < 50 or percentile > 99 do
      {:error,
       %ArgumentError{message: ":percentile must be between 50 and 99, got: #{percentile}"}}
    else
      :ok
    end
  end

  defp validate_adaptive_strategy(opts) do
    candidates = Keyword.get(opts, :delay_candidates, [])

    cond do
      length(candidates) < 2 ->
        {:error,
         %ArgumentError{
           message: ":adaptive strategy requires at least 2 :delay_candidates"
         }}

      not Enum.all?(candidates, &is_integer/1) ->
        {:error,
         %ArgumentError{
           message: ":delay_candidates must be a list of non-negative integers"
         }}

      true ->
        :ok
    end
  end

  defp validate_workload_aware_strategy(_opts) do
    # Workload-aware strategy is flexible and doesn't require specific options
    :ok
  end

  defp validate_exponential_backoff_strategy(opts) do
    min_delay = Keyword.get(opts, :exponential_min_delay, 10)
    max_delay = Keyword.get(opts, :exponential_max_delay, 5000)
    base_delay = Keyword.get(opts, :exponential_base_delay, 100)
    increase_factor = Keyword.get(opts, :exponential_increase_factor, 1.5)
    decrease_factor = Keyword.get(opts, :exponential_decrease_factor, 0.9)
    error_factor = Keyword.get(opts, :exponential_error_factor, 2.0)

    cond do
      min_delay >= max_delay ->
        {:error,
         %ArgumentError{
           message:
             ":exponential_min_delay must be less than :exponential_max_delay, got min=#{min_delay}, max=#{max_delay}"
         }}

      base_delay < min_delay or base_delay > max_delay ->
        {:error,
         %ArgumentError{
           message:
             ":exponential_base_delay must be within [min, max], got base=#{base_delay}, min=#{min_delay}, max=#{max_delay}"
         }}

      increase_factor <= 1.0 ->
        {:error,
         %ArgumentError{
           message:
             ":exponential_increase_factor must be greater than 1.0 for backoff, got #{increase_factor}"
         }}

      decrease_factor >= 1.0 or decrease_factor <= 0.0 ->
        {:error,
         %ArgumentError{
           message:
             ":exponential_decrease_factor must be between 0.0 and 1.0, got #{decrease_factor}"
         }}

      error_factor <= 1.0 ->
        {:error,
         %ArgumentError{
           message:
             ":exponential_error_factor must be greater than 1.0 for backoff, got #{error_factor}"
         }}

      true ->
        :ok
    end
  end

  @doc """
  Returns the NimbleOptions schema for documentation purposes.
  """
  def schema, do: @schema

  @doc """
  Merges user options with defaults.

  ## Examples

      iex> opts = CrucibleHedging.Config.with_defaults([strategy: :fixed, delay_ms: 200])
      iex> opts[:strategy]
      :fixed
      iex> opts[:delay_ms]
      200
      iex> opts[:percentile]
      95
      iex> opts[:timeout_ms]
      30_000
  """
  @spec with_defaults(keyword()) :: keyword()
  def with_defaults(opts) when is_list(opts) do
    defaults = [
      strategy: :percentile,
      strategy_name: nil,
      percentile: 95,
      window_size: 1000,
      initial_delay: 100,
      delay_candidates: [50, 100, 200, 500, 1000],
      learning_rate: 0.1,
      base_delay: 100,
      exponential_base_delay: 100,
      exponential_min_delay: 10,
      exponential_max_delay: 5000,
      exponential_increase_factor: 1.5,
      exponential_decrease_factor: 0.9,
      exponential_error_factor: 2.0,
      max_hedges: 1,
      timeout_ms: 30_000,
      enable_cancellation: true,
      telemetry_prefix: [:crucible_hedging]
    ]

    Keyword.merge(defaults, opts)
  end
end
