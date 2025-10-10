#!/usr/bin/env elixir

# Multi-Tier Hedging Examples
#
# Run with: elixir -S mix run examples/multi_tier.exs

defmodule Examples.MultiTier do
  @moduledoc """
  Examples demonstrating multi-tier hedging for cost optimization
  and improved latency.
  """

  require Logger

  def run do
    Logger.info("=== Multi-Tier Hedging Examples ===\n")

    example_1_three_tier_fallback()
    example_2_quality_based_selection()
    example_3_cost_optimization()
  end

  defp example_1_three_tier_fallback do
    Logger.info("Example 1: Three-Tier Fallback (GPT-4 → GPT-3.5 → Gemini)")
    Logger.info("-------------------------------------------------------------")

    # Simulate three tiers with different latency/quality characteristics
    tiers = [
      %{
        name: :gpt4,
        delay_ms: 500,
        cost: 0.03,
        request_fn: fn ->
          # GPT-4: High quality, often slow
          latency = 300 + :rand.uniform(700)
          Process.sleep(latency)
          %{response: "GPT-4 response", quality: 0.95, latency: latency}
        end
      },
      %{
        name: :gpt35,
        delay_ms: 300,
        cost: 0.002,
        request_fn: fn ->
          # GPT-3.5: Medium quality, medium latency
          latency = 100 + :rand.uniform(300)
          Process.sleep(latency)
          %{response: "GPT-3.5 response", quality: 0.85, latency: latency}
        end
      },
      %{
        name: :gemini,
        delay_ms: 0,
        cost: 0.0001,
        request_fn: fn ->
          # Gemini Flash: Lower quality, very fast
          latency = 50 + :rand.uniform(100)
          Process.sleep(latency)
          %{response: "Gemini response", quality: 0.75, latency: latency}
        end
      }
    ]

    # Make 5 requests
    Enum.each(1..5, fn i ->
      {:ok, result, metadata} = CrucibleHedging.MultiLevel.execute(tiers)

      Logger.info(
        "Request #{i}: Tier=#{metadata.tier} | " <>
          "Quality=#{result.quality} | " <>
          "Latency=#{metadata.total_latency}ms | " <>
          "Cost=$#{Float.round(metadata.total_cost, 4)} | " <>
          "Hedges=#{metadata.hedges_fired}"
      )
    end)

    Logger.info("")
  end

  defp example_2_quality_based_selection do
    Logger.info("Example 2: Quality-Based Tier Selection")
    Logger.info("----------------------------------------")

    # Tiers with quality thresholds
    tiers = [
      %{
        name: :premium,
        delay_ms: 200,
        quality_threshold: 0.9,
        request_fn: fn ->
          # Sometimes returns high quality, sometimes not
          quality = 0.7 + :rand.uniform() * 0.3
          Process.sleep(50)

          %{
            response: "Premium response",
            confidence: quality,
            quality_score: quality
          }
        end
      },
      %{
        name: :standard,
        delay_ms: 100,
        quality_threshold: 0.7,
        request_fn: fn ->
          quality = 0.6 + :rand.uniform() * 0.2
          Process.sleep(30)

          %{
            response: "Standard response",
            confidence: quality,
            quality_score: quality
          }
        end
      },
      %{
        name: :fallback,
        delay_ms: 0,
        quality_threshold: 0.0,
        request_fn: fn ->
          Process.sleep(10)

          %{
            response: "Fallback response",
            confidence: 0.5,
            quality_score: 0.5
          }
        end
      }
    ]

    # Make requests - observe tier selection based on quality
    Enum.each(1..5, fn i ->
      {:ok, result, metadata} = CrucibleHedging.MultiLevel.execute(tiers)

      Logger.info(
        "Request #{i}: Selected=#{metadata.tier} | " <>
          "Quality=#{Float.round(result.quality_score, 2)} | " <>
          "Latency=#{metadata.total_latency}ms"
      )
    end)

    Logger.info("")
  end

  defp example_3_cost_optimization do
    Logger.info("Example 3: Cost Optimization Analysis")
    Logger.info("--------------------------------------")

    # Compare single-tier vs multi-tier cost/latency
    single_tier_results =
      Enum.map(1..10, fn _ ->
        # Simulate expensive single-tier requests
        latency = 200 + :rand.uniform(800)
        Process.sleep(latency)
        %{latency: latency, cost: 0.03}
      end)

    multi_tier_tiers = [
      %{
        name: :expensive,
        delay_ms: 300,
        cost: 0.03,
        request_fn: fn ->
          latency = 200 + :rand.uniform(800)
          Process.sleep(latency)
          :expensive_result
        end
      },
      %{
        name: :cheap,
        delay_ms: 0,
        cost: 0.001,
        request_fn: fn ->
          latency = 50 + :rand.uniform(100)
          Process.sleep(latency)
          :cheap_result
        end
      }
    ]

    multi_tier_results =
      Enum.map(1..10, fn _ ->
        {:ok, _result, metadata} = CrucibleHedging.MultiLevel.execute(multi_tier_tiers)
        %{latency: metadata.total_latency, cost: metadata.total_cost}
      end)

    # Calculate statistics
    single_avg_latency = Enum.map(single_tier_results, & &1.latency) |> avg()
    single_avg_cost = Enum.map(single_tier_results, & &1.cost) |> avg()

    multi_avg_latency = Enum.map(multi_tier_results, & &1.latency) |> avg()
    multi_avg_cost = Enum.map(multi_tier_results, & &1.cost) |> avg()

    Logger.info("Single-Tier Results:")
    Logger.info("  Average latency: #{round(single_avg_latency)}ms")
    Logger.info("  Average cost: $#{Float.round(single_avg_cost, 4)}")

    Logger.info("\nMulti-Tier Results:")
    Logger.info("  Average latency: #{round(multi_avg_latency)}ms")
    Logger.info("  Average cost: $#{Float.round(multi_avg_cost, 4)}")

    latency_improvement = (1 - multi_avg_latency / single_avg_latency) * 100
    cost_savings = (1 - multi_avg_cost / single_avg_cost) * 100

    Logger.info("\nImprovements:")
    Logger.info("  Latency: #{Float.round(latency_improvement, 1)}% faster")
    Logger.info("  Cost: #{Float.round(cost_savings, 1)}% cheaper")
    Logger.info("")
  end

  defp avg([]), do: 0
  defp avg(list), do: Enum.sum(list) / length(list)
end

# Run examples
Examples.MultiTier.run()
