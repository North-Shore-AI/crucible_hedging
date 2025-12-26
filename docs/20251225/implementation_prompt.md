# Implementation Prompt: Crucible.Stage Integration for CrucibleHedging

**Task:** Add a proper `Crucible.Stage` behaviour wrapper to CrucibleHedging that integrates with the crucible_framework pipeline system.

---

## Required Reading

Before implementing, read these files in order:

### 1. Crucible.Stage Behaviour (the target behaviour)
```
/home/home/p/g/North-Shore-AI/crucible_framework/lib/crucible/stage.ex
```
- Lines 1-18: Full behaviour definition
- Note the callbacks: `run/2` and optional `describe/1`
- Note the Context type requirement

### 2. Crucible.Context Struct (required context type)
```
/home/home/p/g/North-Shore-AI/crucible_framework/lib/crucible/context.ex
```
- Lines 68-101: Struct definition
- Lines 107-119: `put_metric/3`
- Lines 163-165: `merge_metrics/2`
- Lines 228-231: `put_artifact/3`
- Lines 243-247: `get_artifact/3`
- Lines 357-361: `mark_stage_complete/2`

### 3. Example Stage Implementation (reference)
```
/home/home/p/g/North-Shore-AI/crucible_framework/lib/crucible/stage/bench.ex
```
- Lines 43: `@behaviour Crucible.Stage`
- Lines 52-86: `run/2` implementation pattern
- Lines 88-96: `describe/1` implementation
- Note how it accesses experiment config: `experiment.reliability.stats`

### 4. Current Hedging Stage (what exists, needs replacement)
```
/home/home/p/g/North-Shore-AI/crucible_hedging/lib/crucible_hedging/stage.ex
```
- Lines 1-376: Current implementation (uses plain maps, NOT Crucible.Context)
- Lines 98-117: Current `run/2` function
- Lines 144-201: Current `describe/1` function

### 5. Main CrucibleHedging Module (core hedging logic to wrap)
```
/home/home/p/g/North-Shore-AI/crucible_hedging/lib/hedging.ex
```
- Lines 143-208: `request/2` function - the core hedging function to use
- Lines 97-123: `from_ir_config/1` - converts IR config to options

### 6. CrucibleIR Hedging Config Struct
```
/home/home/p/g/North-Shore-AI/crucible_ir/lib/crucible_ir/reliability/hedging.ex
```
- Review the struct fields for configuration

### 7. Existing Stage Tests (patterns to follow)
```
/home/home/p/g/North-Shore-AI/crucible_hedging/test/crucible_hedging/stage_test.exs
```
- Lines 1-360: Current tests (need updating for new Context-based implementation)

---

## Implementation Requirements

### 1. Create New Module: CrucibleHedging.CrucibleStage

**File:** `/home/home/p/g/North-Shore-AI/crucible_hedging/lib/crucible_hedging/crucible_stage.ex`

```elixir
defmodule CrucibleHedging.CrucibleStage do
  @moduledoc """
  Crucible.Stage implementation for request hedging.

  This stage wraps CrucibleHedging for use in crucible_framework pipelines.
  It reads hedging configuration from the experiment IR and stores results
  in the context artifacts.

  ## Context Requirements

  Expects the context to have:
  - `context.experiment.reliability.hedging` - %CrucibleIR.Reliability.Hedging{}

  The stage also requires a request function to be provided via options:
  - `opts[:request_fn]` - A 0-arity function to execute with hedging

  ## Outputs

  On success, the stage:
  - Stores hedging result in `context.artifacts[:hedging_result]`
  - Merges hedging metadata into `context.metrics[:hedging]`
  - Marks :hedging stage as complete

  ## Usage

      # In pipeline configuration
      stages: [
        {CrucibleHedging.CrucibleStage, request_fn: fn -> api_call() end}
      ]
  """

  @behaviour Crucible.Stage

  alias Crucible.Context
  alias CrucibleIR.Reliability.Hedging

  require Logger

  @impl Crucible.Stage
  def run(%Context{experiment: experiment} = ctx, opts) do
    # Implementation here
  end

  @impl Crucible.Stage
  def describe(opts) do
    # Implementation here
  end
end
```

### 2. Implementation Details

#### run/2 Function Requirements

1. **Extract hedging config from experiment:**
   ```elixir
   hedging_config = experiment.reliability.hedging
   ```

2. **Get request function from opts:**
   ```elixir
   request_fn = Map.fetch!(opts, :request_fn)
   ```

3. **Handle strategy :off case:**
   - Execute request directly without hedging
   - Still track latency

4. **Handle hedging strategies:**
   - Convert IR config to options using `CrucibleHedging.from_ir_config/1`
   - Call `CrucibleHedging.request/2`

5. **Update context on success:**
   ```elixir
   ctx
   |> Context.put_artifact(:hedging_result, result)
   |> Context.merge_metrics(%{hedging: hedging_metadata})
   |> Context.mark_stage_complete(:hedging)
   ```

6. **Return proper types:**
   - `{:ok, %Context{}}` on success
   - `{:error, term()}` on failure

#### describe/1 Function Requirements

Return a map with:
```elixir
%{
  stage: :hedging,
  description: "Request hedging for tail latency reduction",
  inputs: [...],
  outputs: [...],
  config: %{...}
}
```

---

## Test Requirements

### File: `/home/home/p/g/North-Shore-AI/crucible_hedging/test/crucible_hedging/crucible_stage_test.exs`

#### TDD Approach - Write Tests First

```elixir
defmodule CrucibleHedging.CrucibleStageTest do
  use ExUnit.Case, async: true
  doctest CrucibleHedging.CrucibleStage

  alias Crucible.Context
  alias CrucibleIR.Experiment
  alias CrucibleIR.BackendRef
  alias CrucibleIR.Reliability
  alias CrucibleIR.Reliability.Hedging
  alias CrucibleHedging.CrucibleStage

  # Helper to create a valid context
  defp create_context(hedging_config) do
    %Context{
      experiment_id: "test-exp-1",
      run_id: "run-1",
      experiment: %Experiment{
        id: "test-exp-1",
        backend: %BackendRef{id: :mock},
        reliability: %Reliability{
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
      opts = %{request_fn: fn -> Process.sleep(10); :result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      hedging_metrics = Context.get_metric(updated_ctx, :hedging)
      assert hedging_metrics.total_latency >= 10
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
      ctx = create_context(%Hedging{strategy: :fixed, delay_ms: 50})
      opts = %{request_fn: fn -> Process.sleep(200); :slow end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      hedging_metrics = Context.get_metric(updated_ctx, :hedging)
      assert hedging_metrics.hedged == true
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
      ctx = create_context(%Hedging{
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
      ctx = create_context(%Hedging{
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
      ctx = create_context(%Hedging{
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
          reliability: %Reliability{}  # No hedging config
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

      assert {:error, {:request_failed, _}} = CrucibleStage.run(ctx, opts)
    end
  end

  describe "run/2 preserves context" do
    test "preserves existing metrics" do
      ctx = create_context(%Hedging{strategy: :off})
             |> Context.put_metric(:existing, :value)
      opts = %{request_fn: fn -> :result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      assert Context.get_metric(updated_ctx, :existing) == :value
    end

    test "preserves existing artifacts" do
      ctx = create_context(%Hedging{strategy: :off})
             |> Context.put_artifact(:existing, :artifact)
      opts = %{request_fn: fn -> :result end}

      assert {:ok, updated_ctx} = CrucibleStage.run(ctx, opts)
      assert Context.get_artifact(updated_ctx, :existing) == :artifact
    end

    test "preserves existing assigns" do
      ctx = create_context(%Hedging{strategy: :off})
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
  end
end
```

---

## Quality Requirements

### 1. No Compiler Warnings
```bash
mix compile --warnings-as-errors
```

### 2. Dialyzer Clean
```bash
mix dialyzer
```
- Ensure proper type specs on all public functions

### 3. Credo Strict
```bash
mix credo --strict
```

### 4. All Tests Passing
```bash
mix test
mix test --cover  # Aim for >90% coverage on new code
```

---

## README.md Update

Add this section to `/home/home/p/g/North-Shore-AI/crucible_hedging/README.md`:

```markdown
## Crucible Framework Integration

CrucibleHedging provides a `Crucible.Stage` implementation for use in crucible_framework pipelines:

### Using CrucibleStage in Pipelines

```elixir
# Define experiment with hedging configuration
experiment = %CrucibleIR.Experiment{
  id: "my-experiment",
  backend: %BackendRef{id: :openai},
  reliability: %Reliability{
    hedging: %CrucibleIR.Reliability.Hedging{
      strategy: :percentile,
      percentile: 95,
      max_hedges: 1
    }
  }
}

# Create context
ctx = %Crucible.Context{
  experiment_id: experiment.id,
  run_id: "run-1",
  experiment: experiment
}

# Run hedging stage with request function
{:ok, updated_ctx} = CrucibleHedging.CrucibleStage.run(ctx, %{
  request_fn: fn -> make_api_call() end
})

# Access results
result = Crucible.Context.get_artifact(updated_ctx, :hedging_result)
metadata = Crucible.Context.get_metric(updated_ctx, :hedging)
```

### Stage Outputs

The stage stores:
- **Artifact** `:hedging_result` - The result from the fastest request
- **Metric** `:hedging` - Hedging execution metadata including:
  - `hedged` - Whether a hedge was fired
  - `hedge_won` - Whether the hedge completed first
  - `total_latency` - Total request latency
  - `primary_latency` - Primary request latency
  - `backup_latency` - Backup request latency
  - `hedge_delay` - Delay before hedge was sent
  - `cost` - Request cost factor (1.0 or 2.0)
  - `strategy` - Strategy used
```

---

## Implementation Checklist

- [ ] Read all required files listed above
- [ ] Write test file first (TDD)
- [ ] Create `CrucibleHedging.CrucibleStage` module
- [ ] Implement `run/2` with proper Context handling
- [ ] Implement `describe/1`
- [ ] Add proper @moduledoc and @doc
- [ ] Add type specs (@spec)
- [ ] Run `mix compile --warnings-as-errors`
- [ ] Run `mix dialyzer`
- [ ] Run `mix credo --strict`
- [ ] Run `mix test` - all tests must pass
- [ ] Update README.md with Stage documentation
- [ ] Verify integration by running full test suite

---

## Dependencies Note

Ensure `crucible_framework` is available as a dependency. If not already in mix.exs, add:

```elixir
{:crucible_framework, path: "../crucible_framework"}
# or
{:crucible_framework, "~> 0.4.0"}
```

---

## Success Criteria

1. All tests pass
2. Zero compiler warnings
3. Dialyzer passes
4. Credo strict passes
5. New module properly implements `Crucible.Stage` behaviour
6. Context is properly updated with artifacts and metrics
7. README.md documents the new Stage integration
8. Existing functionality remains unchanged
