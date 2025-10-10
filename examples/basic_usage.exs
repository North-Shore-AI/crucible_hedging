#!/usr/bin/env elixir

# Basic Hedging Usage Examples
#
# Run with: elixir -S mix run examples/basic_usage.exs

defmodule Examples.BasicUsage do
  @moduledoc """
  Basic examples demonstrating hedging usage for latency reduction.
  """

  require Logger

  def run do
    Logger.info("=== Hedging Basic Usage Examples ===\n")

    example_1_fixed_delay()
    example_2_percentile_based()
    example_3_adaptive_learning()
    example_4_workload_aware()
    example_5_metrics_tracking()
  end

  defp example_1_fixed_delay do
    Logger.info("Example 1: Fixed Delay Hedging")
    Logger.info("------------------------------")

    # Simulate an API call with variable latency
    api_call = fn ->
      latency = Enum.random([50, 100, 200, 500, 1000])
      Process.sleep(latency)
      {:ok, "Response after #{latency}ms"}
    end

    # Make 5 requests with fixed 100ms hedge delay
    Enum.each(1..5, fn i ->
      {:ok, result, metadata} =
        CrucibleHedging.request(api_call,
          strategy: :fixed,
          delay_ms: 100
        )

      Logger.info(
        "Request #{i}: #{inspect(result)} | " <>
          "Hedged: #{metadata.hedged} | " <>
          "Total: #{metadata.total_latency}ms"
      )
    end)

    Logger.info("")
  end

  defp example_2_percentile_based do
    Logger.info("Example 2: Percentile-Based Hedging")
    Logger.info("------------------------------------")

    # Start percentile strategy
    {:ok, _pid} = CrucibleHedging.Strategy.Percentile.start_link(percentile: 90)

    # Simulate API with increasing latency pattern
    api_call = fn ->
      latency = :rand.uniform(500)
      Process.sleep(latency)
      {:ok, "Response"}
    end

    # Make requests - strategy learns optimal delay
    Enum.each(1..10, fn i ->
      {:ok, _result, metadata} =
        CrucibleHedging.request(api_call, strategy: :percentile)

      Logger.info(
        "Request #{i}: Delay=#{metadata.hedge_delay}ms | " <>
          "Total=#{metadata.total_latency}ms"
      )
    end)

    # Show learned statistics
    stats = CrucibleHedging.Strategy.Percentile.get_stats()

    Logger.info("\nLearned Statistics:")
    Logger.info("  P50: #{stats.p50}ms")
    Logger.info("  P90: #{stats.p90}ms")
    Logger.info("  P95: #{stats.p95}ms")
    Logger.info("  Current delay: #{stats.current_delay}ms")
    Logger.info("")

    GenServer.stop(CrucibleHedging.Strategy.Percentile)
  end

  defp example_3_adaptive_learning do
    Logger.info("Example 3: Adaptive Learning with Thompson Sampling")
    Logger.info("---------------------------------------------------")

    # Start adaptive strategy with multiple delay candidates
    {:ok, _pid} =
      CrucibleHedging.Strategy.Adaptive.start_link(delay_candidates: [50, 100, 200, 500])

    # Simulate variable latency API
    api_call = fn ->
      # Sometimes fast, sometimes slow
      latency =
        if :rand.uniform() < 0.3 do
          :rand.uniform(100)
        else
          200 + :rand.uniform(300)
        end

      Process.sleep(latency)
      {:ok, "Response"}
    end

    # Make requests - strategy learns best delay
    Enum.each(1..15, fn i ->
      {:ok, _result, metadata} =
        CrucibleHedging.request(api_call, strategy: :adaptive)

      Logger.info(
        "Request #{i}: Delay=#{metadata.hedge_delay}ms | " <>
          "Hedged=#{metadata.hedged} | " <>
          "Won=#{metadata.hedge_won}"
      )
    end)

    # Show learning progress
    stats = CrucibleHedging.Strategy.Adaptive.get_stats()

    Logger.info("\nAdaptive Learning Stats:")
    Logger.info("  Total pulls: #{stats.total_pulls}")

    Enum.each(stats.arms, fn {delay, arm_stats} ->
      Logger.info(
        "  #{delay}ms: pulls=#{arm_stats.pulls}, " <>
          "avg_reward=#{Float.round(arm_stats.avg_reward, 3)}"
      )
    end)

    Logger.info("")

    GenServer.stop(CrucibleHedging.Strategy.Adaptive)
  end

  defp example_4_workload_aware do
    Logger.info("Example 4: Workload-Aware Hedging")
    Logger.info("----------------------------------")

    # Simulate different types of requests
    requests = [
      %{prompt: String.duplicate("x", 100), model: :simple},
      %{prompt: String.duplicate("x", 1000), model: :medium},
      %{prompt: String.duplicate("x", 3000), model: :complex}
    ]

    Enum.each(requests, fn req ->
      api_call = fn ->
        # Longer prompts and complex models take longer
        base = 50
        prompt_factor = String.length(req.prompt) / 100

        model_factor =
          case req.model do
            :simple -> 1
            :medium -> 2
            :complex -> 3
          end

        latency = round(base * prompt_factor * model_factor)
        Process.sleep(latency)
        {:ok, "Response"}
      end

      {:ok, _result, metadata} =
        CrucibleHedging.request(api_call,
          strategy: :workload_aware,
          base_delay: 100,
          prompt_length: String.length(req.prompt),
          model_complexity: req.model
        )

      Logger.info(
        "Prompt: #{String.length(req.prompt)} chars, Model: #{req.model} | " <>
          "Delay: #{metadata.hedge_delay}ms | " <>
          "Total: #{metadata.total_latency}ms"
      )
    end)

    Logger.info("")
  end

  defp example_5_metrics_tracking do
    Logger.info("Example 5: Metrics Tracking")
    Logger.info("----------------------------")

    # Make various requests
    api_call = fn ->
      latency = Enum.random([50, 100, 200, 500])
      Process.sleep(latency)
      {:ok, "Response"}
    end

    Enum.each(1..20, fn _i ->
      {:ok, _result, metadata} =
        CrucibleHedging.request(api_call,
          strategy: :fixed,
          delay_ms: 150
        )

      # Metrics are automatically collected
      CrucibleHedging.Metrics.record(metadata)
    end)

    # Get aggregate statistics
    {:ok, stats} = CrucibleHedging.Metrics.get_stats()

    Logger.info("Aggregate Statistics:")
    Logger.info("  Total requests: #{stats.total_requests}")
    Logger.info("  Hedge rate: #{Float.round(stats.hedge_rate * 100, 1)}%")
    Logger.info("  Hedge win rate: #{Float.round(stats.hedge_win_rate * 100, 1)}%")
    Logger.info("  P50 latency: #{stats.p50_latency}ms")
    Logger.info("  P95 latency: #{stats.p95_latency}ms")
    Logger.info("  P99 latency: #{stats.p99_latency}ms")
    Logger.info("  Average cost: #{Float.round(stats.avg_cost, 2)}x")
    Logger.info("  Cost overhead: #{stats.cost_overhead}%")
    Logger.info("")
  end
end

# Run examples
Examples.BasicUsage.run()
