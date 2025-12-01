defmodule CrucibleHedging.StageTest do
  use ExUnit.Case, async: true
  doctest CrucibleHedging.Stage

  import ExUnit.CaptureLog

  alias CrucibleIR.Reliability.Hedging
  alias CrucibleHedging.Stage

  describe "describe/1" do
    test "returns stage description" do
      description = Stage.describe()

      assert description.name == :hedging
      assert description.description =~ "tail latency"
      assert is_list(description.inputs)
      assert is_list(description.outputs)
      assert is_list(description.config_schema)
    end

    test "describes required inputs" do
      description = Stage.describe()

      input_names = Enum.map(description.inputs, & &1.name)
      assert :experiment in input_names
      assert :request_fn in input_names
    end

    test "describes output fields" do
      description = Stage.describe()

      output_names = Enum.map(description.outputs, & &1.name)
      assert :result in output_names
      assert :hedging_metadata in output_names
    end
  end

  describe "run/2 with :off strategy" do
    test "executes request without hedging" do
      config = %Hedging{strategy: :off}

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> :test_result end
      }

      assert {:ok, updated_context} = Stage.run(context)
      assert updated_context.result == :test_result
      assert updated_context.hedging_metadata.hedged == false
      assert updated_context.hedging_metadata.hedge_won == false
      assert updated_context.hedging_metadata.strategy == :off
      assert is_integer(updated_context.hedging_metadata.total_latency)
      assert updated_context.hedging_metadata.cost == 1.0
    end

    test "captures latency metrics" do
      config = %Hedging{strategy: :off}

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn ->
          Process.sleep(10)
          :result
        end
      }

      assert {:ok, updated_context} = Stage.run(context)
      assert updated_context.hedging_metadata.total_latency >= 10
      assert updated_context.hedging_metadata.primary_latency >= 10
    end
  end

  describe "run/2 with :fixed strategy" do
    test "executes with fixed delay hedging" do
      config = %Hedging{
        strategy: :fixed,
        delay_ms: 100,
        max_hedges: 1
      }

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> :fixed_result end
      }

      assert {:ok, updated_context} = Stage.run(context)
      assert updated_context.result == :fixed_result
      assert updated_context.hedging_metadata.strategy == :fixed
      assert is_map(updated_context.hedging_metadata)
    end

    test "passes delay_ms to hedging engine" do
      config = %Hedging{
        strategy: :fixed,
        delay_ms: 50
      }

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> :result end
      }

      assert {:ok, updated_context} = Stage.run(context)
      assert updated_context.hedging_metadata.hedge_delay == 50
    end
  end

  describe "run/2 with :percentile strategy" do
    test "executes with percentile hedging" do
      config = %Hedging{
        strategy: :percentile,
        percentile: 95
      }

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> :percentile_result end
      }

      assert {:ok, updated_context} = Stage.run(context)
      assert updated_context.result == :percentile_result
      assert updated_context.hedging_metadata.strategy == :percentile
    end
  end

  describe "run/2 with :adaptive strategy" do
    test "executes with adaptive hedging" do
      config = %Hedging{
        strategy: :adaptive,
        options: %{
          "delay_candidates" => [50, 100, 200]
        }
      }

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> :adaptive_result end
      }

      assert {:ok, updated_context} = Stage.run(context)
      assert updated_context.result == :adaptive_result
      assert updated_context.hedging_metadata.strategy == :adaptive
    end
  end

  describe "run/2 with :workload_aware strategy" do
    test "executes with workload-aware hedging" do
      config = %Hedging{
        strategy: :workload_aware,
        options: %{
          "base_delay" => 100,
          "model_complexity" => "complex"
        }
      }

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> :workload_result end
      }

      assert {:ok, updated_context} = Stage.run(context)
      assert updated_context.result == :workload_result
      assert updated_context.hedging_metadata.strategy == :workload_aware
    end
  end

  describe "run/2 with :exponential_backoff strategy" do
    test "executes with exponential backoff hedging" do
      config = %Hedging{
        strategy: :exponential_backoff,
        options: %{
          "exponential_base_delay" => 100,
          "exponential_min_delay" => 10,
          "exponential_max_delay" => 1000
        }
      }

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> :backoff_result end
      }

      assert {:ok, updated_context} = Stage.run(context)
      assert updated_context.result == :backoff_result
      assert updated_context.hedging_metadata.strategy == :exponential_backoff
    end
  end

  describe "run/2 with options override" do
    test "allows overriding timeout_ms" do
      config = %Hedging{strategy: :off}

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> :result end
      }

      assert {:ok, updated_context} = Stage.run(context, timeout_ms: 5000)
      assert updated_context.result == :result
    end

    test "allows overriding strategy" do
      config = %Hedging{strategy: :off}

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> :result end
      }

      # Override should still work, but strategy from context takes precedence
      assert {:ok, updated_context} = Stage.run(context, delay_ms: 200)
      assert updated_context.hedging_metadata.strategy == :off
    end
  end

  describe "run/2 error handling" do
    test "returns error when hedging config is missing" do
      context = %{
        experiment: %{reliability: %{}},
        request_fn: fn -> :result end
      }

      assert {:error, :missing_hedging_config} = Stage.run(context)
    end

    test "returns error when request_fn is missing" do
      config = %Hedging{strategy: :off}

      context = %{
        experiment: %{reliability: %{hedging: config}}
      }

      assert {:error, :missing_request_fn} = Stage.run(context)
    end

    test "returns error when request_fn is not a function" do
      config = %Hedging{strategy: :off}

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: :not_a_function
      }

      assert {:error, {:invalid_request_fn, :not_a_function}} = Stage.run(context)
    end

    test "returns error when hedging config is invalid" do
      context = %{
        experiment: %{reliability: %{hedging: :invalid}},
        request_fn: fn -> :result end
      }

      assert {:error, {:invalid_hedging_config, :invalid}} = Stage.run(context)
    end

    test "handles request function errors" do
      config = %Hedging{strategy: :off}

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> raise "test error" end
      }

      capture_log(fn ->
        assert {:error, {:request_failed, %RuntimeError{message: "test error"}}} =
                 Stage.run(context)
      end)
    end

    test "returns error for invalid strategy" do
      config = %Hedging{strategy: :invalid_strategy}

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> :result end
      }

      assert {:error, {:invalid_strategy, :invalid_strategy}} = Stage.run(context)
    end
  end

  describe "run/2 metadata" do
    test "includes all required metadata fields" do
      config = %Hedging{strategy: :off}

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> :result end
      }

      assert {:ok, updated_context} = Stage.run(context)
      metadata = updated_context.hedging_metadata

      assert Map.has_key?(metadata, :hedged)
      assert Map.has_key?(metadata, :hedge_won)
      assert Map.has_key?(metadata, :total_latency)
      assert Map.has_key?(metadata, :primary_latency)
      assert Map.has_key?(metadata, :backup_latency)
      assert Map.has_key?(metadata, :hedge_delay)
      assert Map.has_key?(metadata, :cost)
      assert Map.has_key?(metadata, :strategy)
    end

    test "preserves existing context fields" do
      config = %Hedging{strategy: :off}

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn -> :result end,
        custom_field: :custom_value,
        another_field: 123
      }

      assert {:ok, updated_context} = Stage.run(context)
      assert updated_context.custom_field == :custom_value
      assert updated_context.another_field == 123
    end
  end

  describe "integration with CrucibleHedging.request/2" do
    test "fast requests complete before hedge delay" do
      config = %Hedging{
        strategy: :fixed,
        delay_ms: 100
      }

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn ->
          Process.sleep(10)
          :fast_result
        end
      }

      assert {:ok, updated_context} = Stage.run(context)
      assert updated_context.result == :fast_result
      assert updated_context.hedging_metadata.hedged == false
    end

    test "slow requests trigger hedge" do
      config = %Hedging{
        strategy: :fixed,
        delay_ms: 50
      }

      context = %{
        experiment: %{reliability: %{hedging: config}},
        request_fn: fn ->
          Process.sleep(200)
          :slow_result
        end
      }

      assert {:ok, updated_context} = Stage.run(context)
      assert updated_context.result == :slow_result
      # Hedge should have been fired due to delay
      assert updated_context.hedging_metadata.hedged == true
    end
  end
end
