# Changelog

All notable changes to this project will be documented in this file.

## [0.2.0] - 2025-11-25

### Added
- **Exponential Backoff Strategy**: New adaptive strategy that adjusts hedge delay based on success/failure patterns
  - Decreases delay on successful hedges (multiplicative decrease)
  - Increases delay on failed hedges and errors (multiplicative increase)
  - Configurable min/max bounds and adjustment factors
  - Ideal for rate-limited APIs and services with variable health
- Strategy naming support to isolate per-backend backoff state
- Enhanced configuration validation for exponential backoff parameters
- Comprehensive test suite for exponential backoff strategy with 100% coverage
- Strategy statistics tracking (consecutive successes/failures, total adjustments)
- Reset capability for exponential backoff strategy

### Enhanced
- Updated `CrucibleHedging.Strategy` to register exponential_backoff strategy
- Added exponential backoff configuration options to `CrucibleHedging.Config`
- Enhanced documentation with exponential backoff usage examples
- Added validation for exponential backoff configuration parameters
- Strategies now react to error outcomes so exponential backoff can increase delay on failures

### Documentation
- Comprehensive design document in `docs/20251125/enhancement_design.md`
- Updated README.md with exponential backoff strategy section
- Added usage examples and algorithm description
- Documented configuration options and validation rules

### Research Foundation
- Based on TCP congestion control (AIMD - Additive Increase Multiplicative Decrease)
- Implements exponential backoff patterns from distributed systems

## [0.1.0] - 2025-10-07

### Added
- Initial release
- Request hedging for tail latency reduction in distributed systems
- Multiple hedging strategies (fixed, percentile-based, adaptive with Thompson Sampling, workload-aware)
- Multi-tier hedging with cascade across providers for cost optimization
- Adaptive learning with online optimization to minimize regret
- Budget-aware hedging with comprehensive cost tracking
- Rich telemetry integration with detailed observability
- Production-ready implementation with lightweight GenServers and proper supervision

### Documentation
- Comprehensive README with examples
- API documentation for all hedging strategies
- Usage examples for LLM inference optimization
- Research foundation based on Google's "The Tail at Scale" paper
- Performance benchmarks showing 75-96% P99 latency reduction
