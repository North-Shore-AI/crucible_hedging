defmodule HedgingTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  doctest CrucibleHedging

  alias CrucibleHedging.Strategy.{Adaptive, Percentile}

  describe "request/2 with fixed strategy" do
    test "completes without hedging when request is fast" do
      {:ok, result, metadata} =
        CrucibleHedging.request(
          fn -> :fast_result end,
          strategy: :fixed,
          delay_ms: 100
        )

      assert result == :fast_result
      assert metadata.hedged == false
      assert metadata.hedge_won == false
      assert is_integer(metadata.primary_latency)
      assert metadata.backup_latency == nil
    end

    test "fires hedge when request is slow" do
      request_fn = blocking_request_fn(self())

      task =
        Task.async(fn ->
          CrucibleHedging.request(request_fn, strategy: :fixed, delay_ms: 0)
        end)

      pids = await_request_starts(2)
      release_requests(pids, :slow_result)

      {:ok, result, metadata} = Task.await(task)

      assert result == :slow_result
      assert metadata.hedged == true
    end

    test "hedge wins when backup completes first" do
      test_pid = self()
      request_fn = blocking_request_fn(test_pid)

      handler_id = "hedge-win-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:crucible_hedging, :hedge, :fired],
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      task =
        Task.async(fn ->
          CrucibleHedging.request(request_fn, strategy: :fixed, delay_ms: 0)
        end)

      assert_receive {:request_started, primary_pid}
      assert_receive {:telemetry, [:crucible_hedging, :hedge, :fired], _measurements, _metadata}
      assert_receive {:request_started, backup_pid}

      backup_ref = Process.monitor(backup_pid)

      release_request(backup_pid, :backup)
      assert_receive {:DOWN, ^backup_ref, :process, ^backup_pid, _reason}
      release_request(primary_pid, :primary)

      {:ok, result, metadata} = Task.await(task)

      assert result == :backup
      assert metadata.hedged == true
      assert metadata.hedge_won == true
      assert metadata.backup_latency != nil
    end

    test "returns error when request fails" do
      {:error, _reason} =
        CrucibleHedging.request(
          fn ->
            raise "Request failed"
          end,
          strategy: :fixed,
          delay_ms: 100
        )
    end

    test "respects timeout" do
      result =
        CrucibleHedging.request(
          fn ->
            receive do
              :never_completes -> :never_completes
            end
          end,
          strategy: :fixed,
          delay_ms: 0,
          timeout_ms: 0
        )

      assert match?({:error, _}, result)
    end
  end

  describe "request/2 with percentile strategy" do
    setup do
      # Stop any existing GenServer first
      case GenServer.whereis(Percentile) do
        nil ->
          :ok

        pid when is_pid(pid) ->
          if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
      end

      # Start the percentile strategy GenServer
      {:ok, _pid} = Percentile.start_link(initial_delay: 100, percentile: 95)

      on_exit(fn ->
        case GenServer.whereis(Percentile) do
          nil ->
            :ok

          pid when is_pid(pid) ->
            if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
        end
      end)

      :ok
    end

    test "uses initial delay when not enough samples" do
      {:ok, _result, metadata} =
        CrucibleHedging.request(
          fn -> :result end,
          strategy: :percentile
        )

      assert metadata.hedge_delay == 100
    end

    test "adapts delay based on observed latencies" do
      # Feed deterministic latencies into the strategy
      Enum.each(1..20, fn i ->
        Percentile.update(%{total_latency: i * 10}, nil)
      end)

      # The delay should now be based on the percentile
      stats = Percentile.get_stats()
      assert stats.sample_count >= 10
      assert stats.current_delay > 100
    end
  end

  describe "request/2 with adaptive strategy" do
    setup do
      # Stop any existing GenServer first
      case GenServer.whereis(Adaptive) do
        nil ->
          :ok

        pid when is_pid(pid) ->
          if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
      end

      {:ok, _pid} = Adaptive.start_link(delay_candidates: [50, 100, 200])

      on_exit(fn ->
        case GenServer.whereis(Adaptive) do
          nil ->
            :ok

          pid when is_pid(pid) ->
            if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
        end
      end)

      :ok
    end

    test "selects delay from candidates" do
      {:ok, _result, metadata} =
        CrucibleHedging.request(
          fn -> :result end,
          strategy: :adaptive,
          delay_candidates: [50, 100, 200]
        )

      assert metadata.hedge_delay in [50, 100, 200]
    end

    test "learns from rewards over time" do
      # Make multiple requests
      Enum.each(1..10, fn _ ->
        CrucibleHedging.request(
          fn -> :result end,
          strategy: :adaptive,
          delay_candidates: [50, 100, 200]
        )
      end)

      stats = Adaptive.get_stats()
      assert stats.total_pulls >= 10
      assert map_size(stats.arms) == 3
    end
  end

  describe "request/2 with workload-aware strategy" do
    test "adjusts delay based on prompt length" do
      {:ok, _result, metadata1} =
        CrucibleHedging.request(
          fn -> :short end,
          strategy: :workload_aware,
          base_delay: 100,
          prompt_length: 100
        )

      {:ok, _result, metadata2} =
        CrucibleHedging.request(
          fn -> :long end,
          strategy: :workload_aware,
          base_delay: 100,
          prompt_length: 3000
        )

      assert metadata2.hedge_delay > metadata1.hedge_delay
    end

    test "adjusts delay based on model complexity" do
      {:ok, _result, metadata_simple} =
        CrucibleHedging.request(
          fn -> :result end,
          strategy: :workload_aware,
          base_delay: 100,
          model_complexity: :simple
        )

      {:ok, _result, metadata_complex} =
        CrucibleHedging.request(
          fn -> :result end,
          strategy: :workload_aware,
          base_delay: 100,
          model_complexity: :complex
        )

      assert metadata_complex.hedge_delay > metadata_simple.hedge_delay
    end
  end

  describe "telemetry events" do
    test "emits request start and stop events" do
      test_pid = self()

      handler_id = "test-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:crucible_hedging, :request, :start],
          [:crucible_hedging, :request, :stop]
        ],
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      CrucibleHedging.request(
        fn -> :result end,
        strategy: :fixed,
        delay_ms: 100
      )

      assert_receive {:telemetry, [:crucible_hedging, :request, :start], _measurements, _metadata}
      assert_receive {:telemetry, [:crucible_hedging, :request, :stop], _measurements, _metadata}
    end

    test "emits hedge fired event when hedge is sent" do
      test_pid = self()
      request_fn = blocking_request_fn(test_pid)

      handler_id = "test-hedge-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:crucible_hedging, :hedge, :fired],
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      task =
        Task.async(fn ->
          CrucibleHedging.request(request_fn, strategy: :fixed, delay_ms: 0)
        end)

      pids = await_request_starts(2)

      assert_receive {:telemetry, [:crucible_hedging, :hedge, :fired], _measurements, _metadata}

      release_requests(pids, :result)

      Task.await(task)
    end
  end

  # Telemetry handler function to avoid warnings
  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end

  defp blocking_request_fn(test_pid) do
    fn ->
      pid = self()
      send(test_pid, {:request_started, pid})

      receive do
        {:release, ^pid, value} -> value
      end
    end
  end

  defp await_request_starts(count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:request_started, pid}
      pid
    end)
  end

  defp release_requests(pids, value) do
    Enum.each(pids, fn pid ->
      release_request(pid, value)
    end)
  end

  defp release_request(pid, value) do
    send(pid, {:release, pid, value})
  end

  describe "edge cases" do
    test "handles request that returns nil" do
      {:ok, result, metadata} =
        CrucibleHedging.request(
          fn -> nil end,
          strategy: :fixed,
          delay_ms: 100
        )

      assert result == nil
      assert metadata.hedged == false
    end

    test "handles concurrent requests" do
      # Make multiple concurrent requests to test for race conditions
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            CrucibleHedging.request(
              fn -> {:ok, i} end,
              strategy: :fixed,
              delay_ms: 25
            )
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _result, _metadata} -> true
               _ -> false
             end)
    end

    test "handles very fast requests (< 1ms)" do
      {:ok, result, metadata} =
        CrucibleHedging.request(
          fn -> :instant end,
          strategy: :fixed,
          delay_ms: 100
        )

      assert result == :instant
      assert metadata.hedged == false
      assert is_integer(metadata.total_latency)
    end

    test "handles requests with custom telemetry prefix" do
      test_pid = self()
      handler_id = "custom-prefix-handler-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:my_app, :hedging, :request, :start],
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

      CrucibleHedging.request(
        fn -> :result end,
        strategy: :fixed,
        delay_ms: 100,
        telemetry_prefix: [:my_app, :hedging]
      )

      assert_receive {:telemetry, [:my_app, :hedging, :request, :start], _measurements, _metadata}

      :telemetry.detach(handler_id)
    end

    test "handles cancellation disabled" do
      # With cancellation disabled, both requests should complete
      request_fn = blocking_request_fn(self())

      task =
        Task.async(fn ->
          CrucibleHedging.request(
            request_fn,
            strategy: :fixed,
            delay_ms: 0,
            enable_cancellation: false
          )
        end)

      pids = await_request_starts(2)
      release_requests(pids, :result)

      {:ok, _result, metadata} = Task.await(task)

      # Should still hedge
      assert metadata.hedged == true
    end
  end

  describe "config validation" do
    test "validates fixed strategy requires delay_ms" do
      assert_raise ArgumentError, fn ->
        CrucibleHedging.Config.validate!(strategy: :fixed)
      end
    end

    test "validates percentile range" do
      assert_raise ArgumentError, fn ->
        CrucibleHedging.Config.validate!(strategy: :percentile, percentile: 100)
      end

      assert_raise ArgumentError, fn ->
        CrucibleHedging.Config.validate!(strategy: :percentile, percentile: 40)
      end
    end

    test "validates adaptive strategy has enough candidates" do
      assert_raise ArgumentError, fn ->
        CrucibleHedging.Config.validate!(strategy: :adaptive, delay_candidates: [100])
      end
    end

    test "accepts valid configuration" do
      {:ok, config} =
        CrucibleHedging.Config.validate(strategy: :percentile, percentile: 95, timeout_ms: 10_000)

      assert config[:strategy] == :percentile
      assert config[:percentile] == 95
      assert config[:timeout_ms] == 10_000
    end
  end
end
