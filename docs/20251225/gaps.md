# CrucibleHedging - Gap Analysis

**Date:** 2025-12-25
**Version:** 0.3.0

---

## Overview

This document identifies gaps and incomplete areas in the current CrucibleHedging implementation.

---

## Critical Gap: Missing Crucible.Stage Behaviour

### Current State
The existing `CrucibleHedging.Stage` module (lib/crucible_hedging/stage.ex) does **NOT** implement the `Crucible.Stage` behaviour from crucible_framework.

**Current implementation:**
```elixir
defmodule CrucibleHedging.Stage do
  # Does NOT have: @behaviour Crucible.Stage
  # Uses plain maps instead of Crucible.Context
  # run/2 signature: run(context, opts) where context is a plain map
end
```

**Required behaviour from crucible_framework:**
```elixir
# From: /home/home/p/g/North-Shore-AI/crucible_framework/lib/crucible/stage.ex
@callback run(context :: Context.t(), opts :: opts()) ::
            {:ok, Context.t()} | {:error, term()}

@callback describe(opts :: opts()) :: map()
@optional_callbacks describe: 1
```

### Gap Details

1. **No `@behaviour Crucible.Stage` declaration**
   - The module doesn't declare it implements the behaviour

2. **Wrong context type**
   - Current: Accepts plain `map()` with nested experiment config
   - Required: Should accept `%Crucible.Context{}` struct

3. **Missing integration with Context helpers**
   - Should use `Crucible.Context.put_artifact/3` to store results
   - Should use `Crucible.Context.merge_metrics/2` for hedging metrics
   - Should use `Crucible.Context.mark_stage_complete/2` for tracking

4. **describe/1 doesn't match behaviour signature**
   - Current: Returns custom description map
   - Required: Should match Stage behaviour expectations

---

## Other Gaps

### 1. Multi-Hedge Implementation Not Fully Used
**Location:** Throughout codebase
**Issue:** `max_hedges` configuration exists but only 1 hedge is ever fired

**Current behavior (lib/hedging.ex, line 256):**
```elixir
nil ->
  # Primary still running, fire hedge
  fire_hedge(...)  # Only fires ONE hedge
```

**Expected:** Should support multiple concurrent hedges based on `max_hedges` setting.

---

### 2. Circuit Breaker Not Implemented
**Location:** Design document mentions this as future work
**Issue:** No circuit breaker integration to prevent cascading failures

**Missing:**
- Circuit breaker state machine (closed -> open -> half_open)
- Per-backend failure tracking
- Automatic circuit opening on failure threshold

---

### 3. Request Deduplication Missing
**Location:** Not implemented
**Issue:** No fingerprinting to handle non-idempotent operations

**Missing:**
- Request fingerprint calculation
- Duplicate response detection
- Coalescing of identical in-flight requests

---

### 4. Histogram Metrics Not Implemented
**Location:** Design document mentions this
**Issue:** Current metrics use simple lists, not O(1) histograms

**Current (lib/crucible_hedging/metrics.ex):**
```elixir
latencies = :queue.in(latency, state.latencies)  # O(n) percentile calculation
```

**Better approach:** HDR Histogram or similar for O(1) percentile queries

---

### 5. Strategy Warmup Not Standardized
**Location:** Various strategy modules
**Issue:** No consistent warmup detection/handling

**Examples:**
- Percentile strategy: Uses `initial_delay` until `min_samples` collected
- Adaptive strategy: Random selection initially
- No coordination or best practices guidance

---

### 6. Missing Rate Limiting Integration
**Location:** Not implemented
**Issue:** No budget-aware hedging or token bucket support

**Missing:**
- Budget tracking (% of requests that can be hedged)
- Token bucket for rate limiting
- Cost-based hedging decisions

---

### 7. Incomplete Error Categorization
**Location:** lib/crucible_hedging/strategy/exponential_backoff.ex
**Issue:** All errors treated the same

**Current (line 218-219):**
```elixir
Map.has_key?(metrics, :error) ->
  GenServer.cast(name, :error)  # Same treatment for all errors
```

**Missing:**
- Retryable vs non-retryable error classification
- Different backoff factors per error type
- Error type in telemetry

---

### 8. No Persistence for Strategy State
**Location:** All GenServer-based strategies
**Issue:** State lost on process restart

**Affected:**
- Percentile strategy: Rolling window lost
- Adaptive strategy: Learning lost
- Exponential backoff: Delay reset to base

**Missing:**
- State persistence option
- Warmup restoration from historical data

---

### 9. Limited Testing for Edge Cases
**Location:** Test files
**Issue:** Some edge cases not covered

**Missing tests:**
- Strategy hot-swapping mid-request
- GenServer restart during active hedging
- Very long-running requests (>30s)
- Memory pressure scenarios

---

### 10. No Graceful Degradation Mode
**Location:** Not implemented
**Issue:** No fallback when hedging infrastructure fails

**Missing:**
- Metrics GenServer unavailable handling
- Strategy GenServer unavailable fallback
- Configurable degradation behavior

---

## Priority Matrix

| Gap | Severity | Effort | Priority |
|-----|----------|--------|----------|
| Missing Crucible.Stage Behaviour | Critical | Medium | P0 |
| Multi-Hedge Implementation | High | Medium | P1 |
| Circuit Breaker | High | High | P2 |
| Request Deduplication | Medium | Medium | P2 |
| Histogram Metrics | Low | Medium | P3 |
| Strategy Warmup | Low | Low | P3 |
| Rate Limiting Integration | Medium | High | P3 |
| Error Categorization | Medium | Low | P2 |
| State Persistence | Low | High | P4 |
| Edge Case Testing | Low | Medium | P3 |
| Graceful Degradation | Medium | Medium | P2 |

---

## Recommendations

### Immediate Action (P0)
1. Create new `CrucibleHedging.CrucibleStage` module that properly implements `Crucible.Stage` behaviour
2. Accept `%Crucible.Context{}` struct
3. Store hedging result in `context.artifacts[:hedging_result]`
4. Store metadata in `context.metrics[:hedging]`
5. Write comprehensive tests

### Short-term (P1-P2)
1. Implement actual multi-hedge support
2. Add circuit breaker integration
3. Categorize errors for better backoff handling

### Medium-term (P3)
1. Consider histogram-based metrics
2. Standardize warmup handling
3. Add more edge case tests

### Long-term (P4)
1. State persistence for strategies
2. Rate limiting integration
