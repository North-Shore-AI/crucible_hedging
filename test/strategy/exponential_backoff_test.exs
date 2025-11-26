defmodule CrucibleHedging.Strategy.ExponentialBackoffTest do
  use ExUnit.Case
  doctest CrucibleHedging.Strategy.ExponentialBackoff

  alias CrucibleHedging.Strategy.ExponentialBackoff

  setup do
    # Stop any existing GenServer first
    case GenServer.whereis(ExponentialBackoff) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
    end

    on_exit(fn ->
      case GenServer.whereis(ExponentialBackoff) do
        nil ->
          :ok

        pid when is_pid(pid) ->
          if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
      end
    end)

    :ok
  end

  describe "calculate_delay/1" do
    test "returns default when server not started" do
      delay = ExponentialBackoff.calculate_delay([])
      assert delay == 100
    end

    test "returns current delay when server is running" do
      {:ok, _pid} = ExponentialBackoff.start_link(base_delay: 200)
      delay = ExponentialBackoff.calculate_delay([])
      assert delay == 200
    end

    test "starts and uses named instance with exponential_* opts" do
      name = :exp_backoff_named

      on_exit(fn ->
        ExponentialBackoff.reset(name)

        case GenServer.whereis(name) do
          nil -> :ok
          pid -> GenServer.stop(pid)
        end
      end)

      delay =
        ExponentialBackoff.calculate_delay(
          strategy_name: name,
          exponential_base_delay: 250,
          exponential_min_delay: 50,
          exponential_max_delay: 750,
          exponential_increase_factor: 2.0,
          exponential_decrease_factor: 0.5,
          exponential_error_factor: 3.0
        )

      assert delay == 250

      stats = ExponentialBackoff.get_stats(name)
      assert stats.min_delay == 50
      assert stats.max_delay == 750
      assert stats.increase_factor == 2.0
      assert stats.decrease_factor == 0.5
      assert stats.error_factor == 3.0
    end
  end

  describe "update/2" do
    test "decreases delay on success (hedge won)" do
      {:ok, _pid} = ExponentialBackoff.start_link(base_delay: 1000, decrease_factor: 0.9)

      initial_delay = ExponentialBackoff.calculate_delay([])
      assert initial_delay == 1000

      # Simulate hedge won
      ExponentialBackoff.update(%{hedge_won: true}, nil)
      Process.sleep(10)

      new_delay = ExponentialBackoff.calculate_delay([])
      assert new_delay == 900
    end

    test "increases delay on failure (hedge fired but didn't win)" do
      {:ok, _pid} = ExponentialBackoff.start_link(base_delay: 100, increase_factor: 1.5)

      initial_delay = ExponentialBackoff.calculate_delay([])
      assert initial_delay == 100

      # Simulate hedge fired but didn't win
      ExponentialBackoff.update(%{hedged: true, hedge_won: false}, nil)
      Process.sleep(10)

      new_delay = ExponentialBackoff.calculate_delay([])
      assert new_delay == 150
    end

    test "aggressively increases delay on error" do
      {:ok, _pid} = ExponentialBackoff.start_link(base_delay: 100, error_factor: 2.0)

      initial_delay = ExponentialBackoff.calculate_delay([])
      assert initial_delay == 100

      # Simulate error
      ExponentialBackoff.update(%{error: :timeout}, nil)
      Process.sleep(10)

      new_delay = ExponentialBackoff.calculate_delay([])
      assert new_delay == 200
    end

    test "clamps delay to minimum" do
      {:ok, _pid} =
        ExponentialBackoff.start_link(base_delay: 100, min_delay: 50, decrease_factor: 0.5)

      # Multiple successes should hit min
      Enum.each(1..10, fn _ ->
        ExponentialBackoff.update(%{hedge_won: true}, nil)
        Process.sleep(5)
      end)

      delay = ExponentialBackoff.calculate_delay([])
      assert delay == 50
    end

    test "clamps delay to maximum" do
      {:ok, _pid} =
        ExponentialBackoff.start_link(base_delay: 100, max_delay: 500, increase_factor: 2.0)

      # Multiple failures should hit max
      Enum.each(1..10, fn _ ->
        ExponentialBackoff.update(%{hedged: true, hedge_won: false}, nil)
        Process.sleep(5)
      end)

      delay = ExponentialBackoff.calculate_delay([])
      assert delay == 500
    end

    test "tracks consecutive successes" do
      {:ok, _pid} = ExponentialBackoff.start_link()

      Enum.each(1..5, fn _ ->
        ExponentialBackoff.update(%{hedge_won: true}, nil)
        Process.sleep(5)
      end)

      stats = ExponentialBackoff.get_stats()
      assert stats.consecutive_successes == 5
      assert stats.consecutive_failures == 0
    end

    test "tracks consecutive failures" do
      {:ok, _pid} = ExponentialBackoff.start_link()

      Enum.each(1..3, fn _ ->
        ExponentialBackoff.update(%{hedged: true, hedge_won: false}, nil)
        Process.sleep(5)
      end)

      stats = ExponentialBackoff.get_stats()
      assert stats.consecutive_failures == 3
      assert stats.consecutive_successes == 0
    end

    test "resets streak on opposite outcome" do
      {:ok, _pid} = ExponentialBackoff.start_link()

      # Build up success streak
      Enum.each(1..3, fn _ ->
        ExponentialBackoff.update(%{hedge_won: true}, nil)
        Process.sleep(5)
      end)

      stats1 = ExponentialBackoff.get_stats()
      assert stats1.consecutive_successes == 3

      # One failure resets
      ExponentialBackoff.update(%{hedged: true, hedge_won: false}, nil)
      Process.sleep(10)

      stats2 = ExponentialBackoff.get_stats()
      assert stats2.consecutive_successes == 0
      assert stats2.consecutive_failures == 1
    end

    test "handles no hedge fired (fast request)" do
      {:ok, _pid} = ExponentialBackoff.start_link(base_delay: 100, decrease_factor: 0.9)

      ExponentialBackoff.update(%{hedged: false}, nil)
      Process.sleep(10)

      # Should treat as success
      delay = ExponentialBackoff.calculate_delay([])
      assert delay == 90
    end

    test "responds to errors via CrucibleHedging.request" do
      {:ok, _pid} =
        ExponentialBackoff.start_link(base_delay: 100, error_factor: 2.0, name: :error_backoff)

      on_exit(fn ->
        case GenServer.whereis(:error_backoff) do
          nil -> :ok
          pid -> GenServer.stop(pid)
        end
      end)

      assert {:error, _} =
               CrucibleHedging.request(
                 fn -> raise "boom" end,
                 strategy: :exponential_backoff,
                 strategy_name: :error_backoff
               )

      Process.sleep(20)

      stats = ExponentialBackoff.get_stats(:error_backoff)
      assert stats.current_delay >= 200
      assert stats.consecutive_failures >= 1
    end
  end

  describe "get_stats/0" do
    test "returns error when not started" do
      assert {:error, :not_started} = ExponentialBackoff.get_stats()
    end

    test "returns comprehensive statistics" do
      {:ok, _pid} =
        ExponentialBackoff.start_link(
          base_delay: 100,
          min_delay: 10,
          max_delay: 5000,
          increase_factor: 1.5,
          decrease_factor: 0.9,
          error_factor: 2.0
        )

      stats = ExponentialBackoff.get_stats()

      assert stats.current_delay == 100
      assert stats.base_delay == 100
      assert stats.min_delay == 10
      assert stats.max_delay == 5000
      assert stats.increase_factor == 1.5
      assert stats.decrease_factor == 0.9
      assert stats.error_factor == 2.0
      assert stats.consecutive_successes == 0
      assert stats.consecutive_failures == 0
      assert stats.total_adjustments == 0
    end

    test "tracks total adjustments" do
      {:ok, _pid} = ExponentialBackoff.start_link()

      ExponentialBackoff.update(%{hedge_won: true}, nil)
      Process.sleep(5)
      ExponentialBackoff.update(%{hedged: true, hedge_won: false}, nil)
      Process.sleep(5)
      ExponentialBackoff.update(%{error: :timeout}, nil)
      Process.sleep(5)

      stats = ExponentialBackoff.get_stats()
      assert stats.total_adjustments == 3
    end
  end

  describe "reset/0" do
    test "resets strategy to initial state" do
      {:ok, _pid} = ExponentialBackoff.start_link(base_delay: 100)

      # Build up some state
      Enum.each(1..5, fn _ ->
        ExponentialBackoff.update(%{hedged: true, hedge_won: false}, nil)
        Process.sleep(5)
      end)

      stats1 = ExponentialBackoff.get_stats()
      assert stats1.current_delay > 100
      assert stats1.consecutive_failures > 0

      # Reset
      ExponentialBackoff.reset()
      Process.sleep(10)

      stats2 = ExponentialBackoff.get_stats()
      assert stats2.current_delay == 100
      assert stats2.consecutive_successes == 0
      assert stats2.consecutive_failures == 0
      assert stats2.total_adjustments == 0
    end
  end

  describe "integration with CrucibleHedging" do
    test "works with request/2" do
      {:ok, _pid} = ExponentialBackoff.start_link(base_delay: 50)

      {:ok, result, metadata} =
        CrucibleHedging.request(
          fn ->
            Process.sleep(10)
            :fast_result
          end,
          strategy: :exponential_backoff
        )

      assert result == :fast_result
      assert metadata.hedge_delay == 50
    end

    test "adapts over multiple requests" do
      {:ok, _pid} =
        ExponentialBackoff.start_link(
          base_delay: 100,
          increase_factor: 1.5,
          decrease_factor: 0.9
        )

      # First request - slow, hedge should fire
      CrucibleHedging.request(
        fn ->
          Process.sleep(200)
          :result
        end,
        strategy: :exponential_backoff
      )

      Process.sleep(50)

      # Delay should have adjusted based on outcome
      stats = ExponentialBackoff.get_stats()
      assert stats.total_adjustments >= 1
    end
  end

  describe "config validation" do
    test "validates exponential backoff config" do
      {:ok, config} =
        CrucibleHedging.Config.validate(
          strategy: :exponential_backoff,
          exponential_min_delay: 10,
          exponential_max_delay: 5000
        )

      assert config[:strategy] == :exponential_backoff
      assert config[:exponential_min_delay] == 10
      assert config[:exponential_max_delay] == 5000
    end

    test "rejects invalid min/max configuration" do
      assert_raise ArgumentError, fn ->
        CrucibleHedging.Config.validate!(
          strategy: :exponential_backoff,
          exponential_min_delay: 5000,
          exponential_max_delay: 100
        )
      end
    end

    test "rejects invalid increase factor" do
      assert_raise ArgumentError, fn ->
        CrucibleHedging.Config.validate!(
          strategy: :exponential_backoff,
          exponential_increase_factor: 0.5
        )
      end
    end

    test "rejects invalid decrease factor" do
      assert_raise ArgumentError, fn ->
        CrucibleHedging.Config.validate!(
          strategy: :exponential_backoff,
          exponential_decrease_factor: 1.5
        )
      end
    end

    test "rejects invalid error factor" do
      assert_raise ArgumentError, fn ->
        CrucibleHedging.Config.validate!(
          strategy: :exponential_backoff,
          exponential_error_factor: 0.5
        )
      end
    end
  end

  describe "edge cases" do
    test "handles rapid updates" do
      {:ok, _pid} = ExponentialBackoff.start_link(base_delay: 100)

      # Rapid fire updates
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            ExponentialBackoff.update(%{hedge_won: :rand.uniform() > 0.5}, nil)
          end)
        end

      Task.await_many(tasks, 1000)
      Process.sleep(50)

      # Should still be responsive
      stats = ExponentialBackoff.get_stats()
      assert is_integer(stats.current_delay)
      assert stats.current_delay >= stats.min_delay
      assert stats.current_delay <= stats.max_delay
    end

    test "handles zero decrease factor approaching min" do
      {:ok, _pid} =
        ExponentialBackoff.start_link(
          base_delay: 100,
          min_delay: 50,
          decrease_factor: 0.1
        )

      # Many successes should converge to min
      Enum.each(1..20, fn _ ->
        ExponentialBackoff.update(%{hedge_won: true}, nil)
        Process.sleep(5)
      end)

      delay = ExponentialBackoff.calculate_delay([])
      assert delay == 50
    end

    test "handles large increase factor" do
      {:ok, _pid} =
        ExponentialBackoff.start_link(
          base_delay: 10,
          max_delay: 10000,
          increase_factor: 5.0
        )

      # Should quickly hit max
      Enum.each(1..5, fn _ ->
        ExponentialBackoff.update(%{hedged: true, hedge_won: false}, nil)
        Process.sleep(5)
      end)

      delay = ExponentialBackoff.calculate_delay([])
      assert delay == 10000
    end
  end
end
