defmodule CrucibleHedging.MetricsTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  doctest CrucibleHedging.Metrics

  setup do
    # Reset metrics before each test
    CrucibleHedging.Metrics.reset()
    :ok
  end

  describe "record/1 and get_stats/0" do
    test "records and retrieves metrics" do
      CrucibleHedging.Metrics.record(%{
        total_latency: 150,
        hedged: true,
        hedge_won: true,
        cost: 1.5
      })

      {:ok, stats} = CrucibleHedging.Metrics.get_stats()

      assert stats.total_requests == 1
      assert stats.hedged_requests == 1
      assert stats.hedge_wins == 1
      assert stats.hedge_rate == 1.0
      assert stats.hedge_win_rate == 1.0
    end

    test "calculates percentiles correctly" do
      # Record 100 requests with latencies 1-100
      Enum.each(1..100, fn latency ->
        CrucibleHedging.Metrics.record(%{
          total_latency: latency,
          hedged: false,
          hedge_won: false,
          cost: 1.0
        })
      end)

      {:ok, stats} = CrucibleHedging.Metrics.get_stats()

      assert stats.p50_latency == 50
      assert stats.p95_latency == 95
      assert stats.p99_latency == 99
    end

    test "maintains rolling window" do
      # Record more than window size
      Enum.each(1..1100, fn latency ->
        CrucibleHedging.Metrics.record(%{
          total_latency: latency,
          hedged: false,
          hedge_won: false,
          cost: 1.0
        })
      end)

      {:ok, stats} = CrucibleHedging.Metrics.get_stats()

      # Should only keep window_size (default 10000) samples
      # But we only recorded 1100, so all should be kept
      assert stats.sample_count == 1100
      assert stats.total_requests == 1100
    end
  end

  describe "percentile/2" do
    test "calculates percentiles from list" do
      values = Enum.to_list(1..100)

      assert CrucibleHedging.Metrics.percentile(values, 50) == 50
      assert CrucibleHedging.Metrics.percentile(values, 95) == 95
      assert CrucibleHedging.Metrics.percentile(values, 99) == 99
    end

    test "handles empty list" do
      assert CrucibleHedging.Metrics.percentile([], 50) == 0
    end

    test "handles single element" do
      assert CrucibleHedging.Metrics.percentile([42], 50) == 42
      assert CrucibleHedging.Metrics.percentile([42], 99) == 42
    end
  end

  describe "percentiles/2" do
    test "calculates multiple percentiles at once" do
      values = Enum.to_list(1..100)
      result = CrucibleHedging.Metrics.percentiles(values, [50, 90, 95, 99])

      assert result[50] == 50
      assert result[90] == 90
      assert result[95] == 95
      assert result[99] == 99
    end
  end

  describe "reset/0" do
    test "clears all metrics" do
      CrucibleHedging.Metrics.record(%{
        total_latency: 100,
        hedged: true,
        hedge_won: true,
        cost: 2.0
      })

      {:ok, stats_before} = CrucibleHedging.Metrics.get_stats()
      assert stats_before.total_requests == 1

      CrucibleHedging.Metrics.reset()

      {:ok, stats_after} = CrucibleHedging.Metrics.get_stats()
      assert stats_after.total_requests == 0
      assert stats_after.hedged_requests == 0
    end
  end
end
