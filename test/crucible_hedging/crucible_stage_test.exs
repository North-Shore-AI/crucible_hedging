defmodule CrucibleHedging.CrucibleStageTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  import ExUnit.CaptureLog

  alias Crucible.Context
  alias CrucibleHedging.CrucibleStage
  alias CrucibleIR.BackendRef
  alias CrucibleIR.Experiment
  alias CrucibleIR.Reliability.Config, as: ReliabilityConfig
  alias CrucibleIR.Reliability.Hedging
  alias CrucibleIR.StageDef

  # Helper to create a valid context with hedging config
  defp create_context(hedging_config) do
    %Context{
      experiment_id: "test-exp-1",
      run_id: "run-1",
      experiment: %Experiment{
        id: "test-exp-1",
        backend: %BackendRef{id: :mock},
        pipeline: [%StageDef{name: :hedging}],
        reliability: %ReliabilityConfig{
          hedging: hedging_config
        }
      }
    }
  end

  describe "behaviour implementation" do
    test "implements Crucible.Stage behaviour" do
      behaviours = CrucibleStage.__info__(:attributes)[:behaviour] || []
      assert Crucible.Stage in behaviours
    end
  end

  describe "run/2 with :off strategy" do
    test "executes request without hedging" do
      ctx = create_context(%Hedging{strategy: :off})
      opts = %{request_fn: fn -> :test_result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      assert Context.get_artifact(updated_ctx, :hedging_result) == :test_result
      assert Context.has_metric?(updated_ctx, :hedging)
      assert Context.stage_completed?(updated_ctx, :hedging)
    end

    test "captures latency in metrics" do
      ctx = create_context(%Hedging{strategy: :off})

      opts = %{
        request_fn: fn -> :result end
      }

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      hedging_metrics = Context.get_metric(updated_ctx, :hedging)
      assert is_integer(hedging_metrics.total_latency)
    end

    test "metrics include strategy :off" do
      ctx = create_context(%Hedging{strategy: :off})
      opts = %{request_fn: fn -> :result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      hedging_metrics = Context.get_metric(updated_ctx, :hedging)
      assert hedging_metrics.strategy == :off
    end
  end

  describe "run/2 with :fixed strategy" do
    test "executes with fixed delay hedging" do
      ctx = create_context(%Hedging{strategy: :fixed, delay_ms: 100})
      opts = %{request_fn: fn -> :hedged_result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      assert Context.get_artifact(updated_ctx, :hedging_result) == :hedged_result
    end

    test "fires hedge for slow requests" do
      ctx = create_context(%Hedging{strategy: :fixed, delay_ms: 0})

      opts = %{
        request_fn: blocking_request_fn(self())
      }

      task = Task.async(fn -> CrucibleStage.run(ctx, opts) end)
      pids = await_request_starts(2)
      release_requests(pids, :slow)

      assert {:ok, updated_ctx} = Task.await(task)
      hedging_metrics = Context.get_metric(updated_ctx, :hedging)
      assert hedging_metrics.hedged == true
    end

    test "does not fire hedge for fast requests" do
      ctx = create_context(%Hedging{strategy: :fixed, delay_ms: 100})

      opts = %{
        request_fn: fn -> :fast end
      }

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      hedging_metrics = Context.get_metric(updated_ctx, :hedging)
      assert hedging_metrics.hedged == false
    end
  end

  describe "run/2 with :percentile strategy" do
    test "executes with percentile hedging" do
      ctx = create_context(%Hedging{strategy: :percentile, percentile: 95})
      opts = %{request_fn: fn -> :percentile_result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      assert Context.get_artifact(updated_ctx, :hedging_result) == :percentile_result
    end
  end

  describe "run/2 with :adaptive strategy" do
    test "executes with adaptive hedging" do
      ctx =
        create_context(%Hedging{
          strategy: :adaptive,
          options: %{"delay_candidates" => [50, 100, 200]}
        })

      opts = %{request_fn: fn -> :adaptive_result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      assert Context.get_artifact(updated_ctx, :hedging_result) == :adaptive_result
    end
  end

  describe "run/2 with :workload_aware strategy" do
    test "executes with workload-aware hedging" do
      ctx =
        create_context(%Hedging{
          strategy: :workload_aware,
          options: %{"base_delay" => 100}
        })

      opts = %{request_fn: fn -> :workload_result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      assert Context.get_artifact(updated_ctx, :hedging_result) == :workload_result
    end
  end

  describe "run/2 with :exponential_backoff strategy" do
    test "executes with exponential backoff hedging" do
      ctx =
        create_context(%Hedging{
          strategy: :exponential_backoff,
          options: %{
            "exponential_base_delay" => 100,
            "exponential_min_delay" => 10,
            "exponential_max_delay" => 1000
          }
        })

      opts = %{request_fn: fn -> :backoff_result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      assert Context.get_artifact(updated_ctx, :hedging_result) == :backoff_result
    end
  end

  describe "run/2 error handling" do
    test "returns error when request_fn not provided" do
      ctx = create_context(%Hedging{strategy: :off})
      opts = %{}

      assert {:error, :missing_request_fn} = CrucibleStage.run(ctx, opts)
    end

    test "returns error when request_fn is not a function" do
      ctx = create_context(%Hedging{strategy: :off})
      opts = %{request_fn: :not_a_function}

      assert {:error, {:invalid_request_fn, :not_a_function}} = CrucibleStage.run(ctx, opts)
    end

    test "returns error when hedging config is missing" do
      ctx = %Context{
        experiment_id: "test",
        run_id: "run",
        experiment: %Experiment{
          id: "test",
          backend: %BackendRef{id: :mock},
          pipeline: [%StageDef{name: :hedging}],
          reliability: %ReliabilityConfig{}
        }
      }

      opts = %{request_fn: fn -> :result end}

      assert {:error, :missing_hedging_config} = CrucibleStage.run(ctx, opts)
    end

    test "returns error for invalid strategy" do
      ctx = create_context(%Hedging{strategy: :invalid})
      opts = %{request_fn: fn -> :result end}

      assert {:error, {:invalid_strategy, :invalid}} = CrucibleStage.run(ctx, opts)
    end

    test "handles request function exceptions" do
      ctx = create_context(%Hedging{strategy: :off})
      opts = %{request_fn: fn -> raise "boom" end}

      capture_log(fn ->
        assert {:error, {:request_failed, _}} = CrucibleStage.run(ctx, opts)
      end)
    end
  end

  describe "run/2 preserves context" do
    test "preserves existing metrics" do
      ctx =
        create_context(%Hedging{strategy: :off})
        |> Context.put_metric(:existing, :value)

      opts = %{request_fn: fn -> :result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      assert Context.get_metric(updated_ctx, :existing) == :value
    end

    test "preserves existing artifacts" do
      ctx =
        create_context(%Hedging{strategy: :off})
        |> Context.put_artifact(:existing, :artifact)

      opts = %{request_fn: fn -> :result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      assert Context.get_artifact(updated_ctx, :existing) == :artifact
    end

    test "preserves existing assigns" do
      ctx =
        create_context(%Hedging{strategy: :off})
        |> Context.assign(:custom, :value)

      opts = %{request_fn: fn -> :result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      assert updated_ctx.assigns.custom == :value
    end
  end

  describe "describe/1" do
    test "returns stage description" do
      description = CrucibleStage.describe(%{})

      assert description.stage == :hedging
      assert is_binary(description.description)
    end

    test "includes input requirements" do
      description = CrucibleStage.describe(%{})

      assert is_list(description.inputs)
    end

    test "includes output specifications" do
      description = CrucibleStage.describe(%{})

      assert is_list(description.outputs)
    end

    test "includes config from opts" do
      description = CrucibleStage.describe(%{strategy: :fixed, delay_ms: 100})

      assert description.config.strategy == :fixed
      assert description.config.delay_ms == 100
    end
  end

  describe "hedging metadata" do
    test "includes all required metadata fields" do
      ctx = create_context(%Hedging{strategy: :off})
      opts = %{request_fn: fn -> :result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      metadata = Context.get_metric(updated_ctx, :hedging)

      assert Map.has_key?(metadata, :hedged)
      assert Map.has_key?(metadata, :hedge_won)
      assert Map.has_key?(metadata, :total_latency)
      assert Map.has_key?(metadata, :primary_latency)
      assert Map.has_key?(metadata, :backup_latency)
      assert Map.has_key?(metadata, :hedge_delay)
      assert Map.has_key?(metadata, :cost)
      assert Map.has_key?(metadata, :strategy)
    end
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
      send(pid, {:release, pid, value})
    end)
  end
end
