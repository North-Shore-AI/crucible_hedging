# CrucibleHedging - Current State Documentation

**Date:** 2025-12-25
**Version:** 0.3.0
**Repository:** /home/home/p/g/North-Shore-AI/crucible_hedging

---

## Overview

CrucibleHedging is an Elixir library implementing request hedging for tail latency reduction in distributed systems. Based on Google's "The Tail at Scale" research (Dean & Barroso, 2013), it achieves 75-96% P99 latency reduction with only 5-10% cost overhead.

---

## Architecture

### Application Structure

```
crucible_hedging/
├── lib/
│   ├── hedging.ex                           # Main module (CrucibleHedging)
│   └── crucible_hedging/
│       ├── application.ex                   # OTP Application
│       ├── config.ex                        # NimbleOptions configuration validation
│       ├── metrics.ex                       # Metrics collection GenServer
│       ├── multi_level.ex                   # Multi-tier hedging
│       ├── stage.ex                         # Pipeline stage (CrucibleIR integration)
│       └── strategy/
│           ├── fixed.ex                     # Fixed delay strategy
│           ├── percentile.ex                # Percentile-based strategy (GenServer)
│           ├── adaptive.ex                  # Thompson Sampling strategy (GenServer)
│           ├── workload_aware.ex            # Context-sensitive strategy
│           └── exponential_backoff.ex       # Adaptive backoff strategy (GenServer)
│       └── strategy.ex                      # Strategy behaviour definition
├── test/
│   ├── hedging_test.exs                     # Main hedging tests
│   ├── config_test.exs                      # Configuration validation tests
│   ├── metrics_test.exs                     # Metrics tests
│   ├── multi_level_test.exs                 # Multi-tier hedging tests
│   └── crucible_hedging/
│       └── stage_test.exs                   # Stage integration tests
│   └── strategy/
│       └── exponential_backoff_test.exs     # Exponential backoff tests
├── examples/
│   ├── basic_usage.exs                      # Basic usage examples
│   └── multi_tier.exs                       # Multi-tier hedging examples
└── mix.exs                                  # Project configuration
```

---

## Module Inventory

### Core Modules

#### 1. CrucibleHedging (lib/hedging.ex)
**Purpose:** Main public API for request hedging

**Key Functions:**
- `request/2` (line 143) - Execute request with hedging
- `from_ir_config/1` (line 97) - Convert CrucibleIR config to options

**Types:**
- `@type request_fn :: (-> any())`
- `@type opts :: keyword()`
- `@type result :: {:ok, any(), metadata :: map()} | {:error, any()}`

**Private Functions:**
- `execute_with_hedging/5` (line 212) - Core hedging execution logic
- `fire_hedge/8` (line 270) - Fire backup request
- `find_first_result/1` (line 346) - Race resolution
- `cancel_slower_tasks/4` (line 371) - Task cancellation

#### 2. CrucibleHedging.Strategy (lib/crucible_hedging/strategy.ex)
**Purpose:** Behaviour definition for hedging strategies

**Callbacks:**
- `calculate_delay/1` (line 41) - Returns delay in milliseconds
- `update/2` (line 49) - Updates strategy state

**Key Functions:**
- `get_strategy/1` (line 54-60) - Strategy module resolution

#### 3. CrucibleHedging.Config (lib/crucible_hedging/config.ex)
**Purpose:** Configuration validation using NimbleOptions

**Key Functions:**
- `validate/1` (line 193) - Validates configuration
- `validate!/1` (line 221) - Validates with exception on error
- `with_defaults/1` (line 372) - Merges defaults
- `schema/0` (line 354) - Returns NimbleOptions schema

**Validation Functions (private):**
- `validate_fixed_strategy/1` (line 254)
- `validate_percentile_strategy/1` (line 265)
- `validate_adaptive_strategy/1` (line 276)
- `validate_workload_aware_strategy/1` (line 297)
- `validate_exponential_backoff_strategy/1` (line 302)

#### 4. CrucibleHedging.Metrics (lib/crucible_hedging/metrics.ex)
**Purpose:** Metrics collection GenServer

**Key Functions:**
- `start_link/1` (line 55) - Start metrics collector
- `record/1` (line 62) - Record hedging metrics
- `get_stats/0` (line 72) - Get current statistics
- `reset/0` (line 82) - Reset all metrics
- `percentile/2` (line 233) - Calculate percentile from list
- `percentiles/2` (line 247) - Calculate multiple percentiles

**GenServer Callbacks:**
- `handle_cast({:record, metrics}, state)` (line 106)
- `handle_call(:get_stats, _from, state)` (line 151)

#### 5. CrucibleHedging.MultiLevel (lib/crucible_hedging/multi_level.ex)
**Purpose:** Multi-tier hedging across providers

**Key Functions:**
- `execute/2` (line 100) - Execute multi-tier hedging

**Private Functions:**
- `execute_tier/2` (line 153, 175) - Tier execution logic
- `meets_quality_threshold?/2` (line 268) - Quality validation
- `select_best_result/1` (line 278) - Best result selection
- `cancel_remaining_tasks/2` (line 351) - Cleanup

#### 6. CrucibleHedging.Stage (lib/crucible_hedging/stage.ex)
**Purpose:** Pipeline stage for CrucibleIR integration

**Key Functions:**
- `run/2` (line 98) - Execute hedging stage
- `describe/1` (line 144) - Stage description

**Private Functions:**
- `extract_hedging_config/1` (line 205)
- `extract_request_fn/1` (line 218)
- `execute_without_hedging/2` (line 231)
- `execute_with_hedging/4` (line 260)
- `build_hedging_opts/2` (line 285)

#### 7. CrucibleHedging.Application (lib/crucible_hedging/application.ex)
**Purpose:** OTP Application supervision

**Children:**
- `CrucibleHedging.Metrics` - Started by default

---

### Strategy Modules

#### 1. CrucibleHedging.Strategy.Fixed (lib/crucible_hedging/strategy/fixed.ex)
**Purpose:** Simple fixed delay hedging

**Key Functions:**
- `calculate_delay/1` (line 33) - Returns configured delay_ms
- `update/2` (line 38) - No-op (stateless)

**Default:** 100ms

#### 2. CrucibleHedging.Strategy.Percentile (lib/crucible_hedging/strategy/percentile.ex)
**Purpose:** Percentile-based hedging with rolling window

**Key Functions:**
- `start_link/1` (line 55) - Start GenServer
- `calculate_delay/1` (line 59) - Get current delay
- `update/2` (line 71) - Update with new latency
- `get_stats/0` (line 194) - Get strategy statistics

**State:**
- Rolling window of latencies (default: 1000)
- Current calculated delay
- Target percentile (default: 95)

#### 3. CrucibleHedging.Strategy.Adaptive (lib/crucible_hedging/strategy/adaptive.ex)
**Purpose:** Thompson Sampling multi-armed bandit

**Key Functions:**
- `start_link/1` (line 52) - Start GenServer
- `calculate_delay/1` (line 56) - Select delay via Thompson Sampling
- `update/2` (line 69) - Update arm rewards
- `get_stats/0` (line 245) - Get arm statistics
- `calculate_reward/1` (line 205) - Reward calculation

**State:**
- Beta distribution parameters per delay candidate
- Pull counts and total rewards

#### 4. CrucibleHedging.Strategy.WorkloadAware (lib/crucible_hedging/strategy/workload_aware.ex)
**Purpose:** Context-sensitive delay adjustment

**Key Functions:**
- `calculate_delay/1` (line 41) - Calculate adjusted delay
- `update/2` (line 55) - No-op (stateless)

**Adjustment Factors:**
- Prompt length: 1x-2.5x
- Model complexity: 0.5x-2x
- Time of day: 0.7x-1.3x
- Priority: 0.6x-1.5x

#### 5. CrucibleHedging.Strategy.ExponentialBackoff (lib/crucible_hedging/strategy/exponential_backoff.ex)
**Purpose:** Adaptive backoff based on success/failure patterns

**Key Functions:**
- `start_link/1` (line 176) - Start GenServer
- `calculate_delay/1` (line 183) - Get current delay
- `update/2` (line 198) - Update based on outcome
- `get_stats/1` (line 244) - Get strategy statistics
- `reset/1` (line 257) - Reset to base delay

**State:**
- Current delay (clamped to [min, max])
- Consecutive success/failure counts
- Total adjustments

---

## Dependencies

From mix.exs (lines 31-38):

```elixir
{:crucible_ir, "~> 0.1.1"},      # IR configuration structs
{:telemetry, "~> 1.2"},          # Telemetry events
{:nimble_options, "~> 1.0"},     # Configuration validation
{:ex_doc, "~> 0.31", only: :dev},
{:dialyxir, "~> 1.4", only: :dev}
```

---

## Telemetry Events

Emitted events:
- `[:crucible_hedging, :request, :start]`
- `[:crucible_hedging, :request, :stop]`
- `[:crucible_hedging, :request, :exception]`
- `[:crucible_hedging, :request, :cancelled]`
- `[:crucible_hedging, :hedge, :fired]`
- `[:crucible_hedging, :hedge, :won]`

Multi-level events:
- `[:crucible_hedging, :multi_level, :start]`
- `[:crucible_hedging, :multi_level, :stop]`
- `[:crucible_hedging, :multi_level, :exception]`
- `[:crucible_hedging, :multi_level, :tier, :start]`
- `[:crucible_hedging, :multi_level, :tier, :completed]`
- `[:crucible_hedging, :multi_level, :tier, :timeout]`
- `[:crucible_hedging, :multi_level, :tier, :cancelled]`

---

## Configuration Schema

Full configuration options (from config.ex):

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `strategy` | atom | `:percentile` | Strategy to use |
| `strategy_name` | atom | nil | Process name for state isolation |
| `delay_ms` | non_neg_integer | - | Fixed delay (required for :fixed) |
| `percentile` | non_neg_integer | 95 | Target percentile (50-99) |
| `window_size` | pos_integer | 1000 | Rolling window size |
| `initial_delay` | non_neg_integer | 100 | Initial delay before warmup |
| `delay_candidates` | list | [50,100,200,500,1000] | Adaptive candidates |
| `learning_rate` | float | 0.1 | Adaptive learning rate |
| `base_delay` | non_neg_integer | 100 | Workload-aware base delay |
| `prompt_length` | non_neg_integer | - | Prompt length |
| `model_complexity` | atom | - | :simple/:medium/:complex |
| `time_of_day` | atom | - | :peak/:normal/:off_peak |
| `priority` | atom | - | :low/:normal/:high |
| `exponential_base_delay` | non_neg_integer | 100 | Backoff initial delay |
| `exponential_min_delay` | non_neg_integer | 10 | Backoff minimum |
| `exponential_max_delay` | non_neg_integer | 5000 | Backoff maximum |
| `exponential_increase_factor` | float | 1.5 | Failure multiplier |
| `exponential_decrease_factor` | float | 0.9 | Success multiplier |
| `exponential_error_factor` | float | 2.0 | Error multiplier |
| `max_hedges` | pos_integer | 1 | Maximum backup requests |
| `timeout_ms` | pos_integer | 30000 | Total request timeout |
| `enable_cancellation` | boolean | true | Cancel slower requests |
| `telemetry_prefix` | list | [:crucible_hedging] | Telemetry prefix |

---

## Existing CrucibleIR Integration

The library already integrates with CrucibleIR through:

1. **CrucibleHedging.Stage** - Pipeline stage implementation
   - Reads config from `context.experiment.reliability.hedging`
   - Expects `%CrucibleIR.Reliability.Hedging{}` struct
   - Returns updated context with `:result` and `:hedging_metadata`

2. **CrucibleHedging.from_ir_config/1** - Direct IR config conversion
   - Converts `%CrucibleIR.Reliability.Hedging{}` to keyword options

---

## Test Coverage

### Test Files
- `test/hedging_test.exs` - 17 test cases
- `test/config_test.exs` - 8 test cases
- `test/metrics_test.exs` - 7 test cases
- `test/multi_level_test.exs` - 5 test cases
- `test/crucible_hedging/stage_test.exs` - 22 test cases
- `test/strategy/exponential_backoff_test.exs` - 26 test cases

### Coverage Areas
- All strategies
- Edge cases (nil results, concurrent requests, fast requests)
- Telemetry event emission
- Configuration validation
- Error handling
- Multi-tier hedging
- CrucibleIR Stage integration

---

## Quality Status

### Compilation
- Zero warnings expected

### Dialyzer
- PLT file at `priv/plts/dialyzer.plt`
- Clean expected

### Credo
- No major issues expected

### Documentation
- Full @moduledoc on all modules
- @doc on all public functions
- README.md with comprehensive examples
- CHANGELOG.md maintained

---

## Version History

- **v0.1.0** - Initial release with fixed, percentile, adaptive, workload-aware strategies
- **v0.2.0** - Added exponential backoff strategy
- **v0.3.0** - Added CrucibleIR integration and Stage module
