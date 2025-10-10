defmodule HedgingTest do
  use ExUnit.Case
  doctest CrucibleHedging

  describe "request/2 with fixed strategy" do
    test "completes without hedging when request is fast" do
      {:ok, result, metadata} =
        CrucibleHedging.request(
          fn ->
            Process.sleep(10)
            :fast_result
          end,
          strategy: :fixed,
          delay_ms: 100
        )

      assert result == :fast_result
      assert metadata.hedged == false
      assert metadata.hedge_won == false
      assert metadata.primary_latency > 0
      assert metadata.backup_latency == nil
    end

    test "fires hedge when request is slow" do
      {:ok, result, metadata} =
        CrucibleHedging.request(
          fn ->
            Process.sleep(200)
            :slow_result
          end,
          strategy: :fixed,
          delay_ms: 50
        )

      assert result == :slow_result
      assert metadata.hedged == true
      assert metadata.total_latency < 300
    end

    test "hedge wins when backup completes first" do
      # Use an Agent to track call count in a deterministic way
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      request_fn = fn ->
        # Atomically increment and get the call number
        call_number = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)

        case call_number do
          1 ->
            # Primary is slow
            Process.sleep(500)
            :primary

          _ ->
            # Backup is fast
            Process.sleep(10)
            :backup
        end
      end

      {:ok, result, metadata} =
        CrucibleHedging.request(request_fn, strategy: :fixed, delay_ms: 50)

      Agent.stop(counter)

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
            Process.sleep(10_000)
            :never_completes
          end,
          strategy: :fixed,
          delay_ms: 50,
          timeout_ms: 100
        )

      assert match?({:error, _}, result)
    end
  end

  describe "request/2 with percentile strategy" do
    setup do
      # Stop any existing GenServer first
      case GenServer.whereis(CrucibleHedging.Strategy.Percentile) do
        nil ->
          :ok

        pid when is_pid(pid) ->
          if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
      end

      # Start the percentile strategy GenServer
      {:ok, _pid} =
        CrucibleHedging.Strategy.Percentile.start_link(initial_delay: 100, percentile: 95)

      on_exit(fn ->
        case GenServer.whereis(CrucibleHedging.Strategy.Percentile) do
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
          fn ->
            Process.sleep(10)
            :result
          end,
          strategy: :percentile
        )

      assert metadata.hedge_delay == 100
    end

    test "adapts delay based on observed latencies" do
      # Generate some requests with known latencies
      Enum.each(1..20, fn i ->
        latency = i * 10

        CrucibleHedging.request(
          fn ->
            Process.sleep(latency)
            :result
          end,
          strategy: :percentile
        )
      end)

      # The delay should now be based on the percentile
      stats = CrucibleHedging.Strategy.Percentile.get_stats()
      assert stats.sample_count >= 10
      assert stats.current_delay > 100
    end
  end

  describe "request/2 with adaptive strategy" do
    setup do
      # Stop any existing GenServer first
      case GenServer.whereis(CrucibleHedging.Strategy.Adaptive) do
        nil ->
          :ok

        pid when is_pid(pid) ->
          if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
      end

      {:ok, _pid} =
        CrucibleHedging.Strategy.Adaptive.start_link(delay_candidates: [50, 100, 200])

      on_exit(fn ->
        case GenServer.whereis(CrucibleHedging.Strategy.Adaptive) do
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
          fn ->
            Process.sleep(10)
            :result
          end,
          strategy: :adaptive,
          delay_candidates: [50, 100, 200]
        )

      assert metadata.hedge_delay in [50, 100, 200]
    end

    test "learns from rewards over time" do
      # Make multiple requests
      Enum.each(1..10, fn _ ->
        CrucibleHedging.request(
          fn ->
            Process.sleep(:rand.uniform(100))
            :result
          end,
          strategy: :adaptive,
          delay_candidates: [50, 100, 200]
        )
      end)

      stats = CrucibleHedging.Strategy.Adaptive.get_stats()
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

      :telemetry.attach_many(
        "test-handler",
        [
          [:crucible_hedging, :request, :start],
          [:crucible_hedging, :request, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      CrucibleHedging.request(
        fn -> :result end,
        strategy: :fixed,
        delay_ms: 100
      )

      assert_receive {:telemetry, [:crucible_hedging, :request, :start], _measurements, _metadata}
      assert_receive {:telemetry, [:crucible_hedging, :request, :stop], _measurements, _metadata}

      :telemetry.detach("test-handler")
    end

    test "emits hedge fired event when hedge is sent" do
      test_pid = self()

      :telemetry.attach(
        "test-hedge-handler",
        [:crucible_hedging, :hedge, :fired],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      CrucibleHedging.request(
        fn ->
          Process.sleep(200)
          :result
        end,
        strategy: :fixed,
        delay_ms: 50
      )

      assert_receive {:telemetry, [:crucible_hedging, :hedge, :fired], _measurements, _metadata}

      :telemetry.detach("test-hedge-handler")
    end
  end
end
