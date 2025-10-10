defmodule CrucibleHedging.Strategy.WorkloadAware do
  @moduledoc """
  Workload-aware hedging that varies delay by request characteristics.

  Adjusts hedge delay based on request features such as:
  - Prompt/payload length (longer → expect longer latency)
  - Model complexity (GPT-4 vs GPT-3.5)
  - Time of day (peak hours → higher variance)
  - Request type or priority

  ## Characteristics

  - **Pros**: Context-sensitive, better than fixed delay
  - **Cons**: Requires request metadata, manual tuning
  - **Use Case**: Diverse request types with predictable patterns

  ## Options

  - `:base_delay` - Base delay in milliseconds (default: 100)
  - `:prompt_length` - Length of prompt/payload
  - `:model_complexity` - `:simple`, `:medium`, or `:complex`
  - `:time_of_day` - `:peak`, `:normal`, or `:off_peak`
  - `:priority` - `:high`, `:normal`, or `:low`

  ## Example

      CrucibleHedging.request(
        fn -> make_api_call(prompt) end,
        strategy: :workload_aware,
        base_delay: 100,
        prompt_length: String.length(prompt),
        model_complexity: :complex
      )
  """

  @behaviour CrucibleHedging.Strategy

  @default_base_delay 100

  @impl CrucibleHedging.Strategy
  def calculate_delay(opts) do
    base_delay = Keyword.get(opts, :base_delay, @default_base_delay)

    # Adjust based on various context factors
    base_delay
    |> adjust_for_prompt_length(Keyword.get(opts, :prompt_length))
    |> adjust_for_model(Keyword.get(opts, :model_complexity))
    |> adjust_for_time(Keyword.get(opts, :time_of_day))
    |> adjust_for_priority(Keyword.get(opts, :priority))
    |> round()
    |> max(10)
  end

  @impl CrucibleHedging.Strategy
  def update(_metrics, state), do: state

  # Private adjustment functions

  defp adjust_for_prompt_length(delay, nil), do: delay

  defp adjust_for_prompt_length(delay, length) when length > 4000 do
    # Very long prompts → expect much longer latency
    delay * 2.5
  end

  defp adjust_for_prompt_length(delay, length) when length > 2000 do
    # Long prompts → expect longer latency
    delay * 2.0
  end

  defp adjust_for_prompt_length(delay, length) when length > 1000 do
    # Medium prompts → slightly longer latency
    delay * 1.5
  end

  defp adjust_for_prompt_length(delay, _length) do
    # Short prompts → use base delay
    delay
  end

  defp adjust_for_model(delay, nil), do: delay

  defp adjust_for_model(delay, :complex) do
    # Complex models (GPT-4, Claude Opus) → longer latency
    delay * 2.0
  end

  defp adjust_for_model(delay, :medium) do
    # Medium models (GPT-3.5, Claude Sonnet) → normal latency
    delay
  end

  defp adjust_for_model(delay, :simple) do
    # Simple models (GPT-3.5-turbo, Gemini Flash) → faster
    delay * 0.5
  end

  defp adjust_for_model(delay, _other), do: delay

  defp adjust_for_time(delay, nil), do: delay

  defp adjust_for_time(delay, :peak) do
    # Peak hours → higher variance, hedge sooner
    delay * 0.7
  end

  defp adjust_for_time(delay, :off_peak) do
    # Off-peak → lower variance, can wait longer
    delay * 1.3
  end

  defp adjust_for_time(delay, :normal) do
    delay
  end

  defp adjust_for_time(delay, _other), do: delay

  defp adjust_for_priority(delay, nil), do: delay

  defp adjust_for_priority(delay, :high) do
    # High priority → hedge aggressively
    delay * 0.6
  end

  defp adjust_for_priority(delay, :normal) do
    delay
  end

  defp adjust_for_priority(delay, :low) do
    # Low priority → can tolerate higher latency
    delay * 1.5
  end

  defp adjust_for_priority(delay, _other), do: delay
end
