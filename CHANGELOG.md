# Changelog

All notable changes to this project will be documented in this file.

## [0.4.1] - 2025-12-28

### Changed
- Updated `crucible_framework` dependency from `~> 0.5.0` to `~> 0.5.2`
- Updated `telemetry` dependency from `~> 1.2` to `~> 1.3`
- Updated `postgrex` dependency from `>= 0.0.0` to `>= 0.21.1`
- Updated `supertester` dependency from `~> 0.3.1` to `~> 0.4.0`

## [0.4.0] - 2025-12-26

### Changed
- **Canonical Schema Format**: Normalized `describe/1` to the canonical schema format as defined in the Stage Describe Contract specification v1.0.0
  - Changed `:stage` key to `:name` key (atom value)
  - Added `required`, `optional`, `types`, `defaults` fields for option validation
  - Moved `inputs`/`outputs` to `__extensions__.hedging` namespace
  - Added schema version marker (`__schema_version__: "1.0.0"`)
- Updated `crucible_framework` dependency from `~> 0.4.0` to `~> 0.5.0`

### Added
- **Conformance Tests**: New `test/crucible_hedging/conformance_test.exs` verifying stage contract compliance
- **Stage Contract Documentation**: Added Stage Contract section to README.md with schema introspection examples
- Type specifications for all options in the canonical format

### Documentation
- Updated README.md with Stage Contract section documenting required/optional options
- Added schema introspection code examples

## [0.3.0] - 2025-12-25

### Added
- **Crucible Framework Integration**: Added `CrucibleHedging.CrucibleStage` module implementing `Crucible.Stage` behaviour for seamless pipeline integration
  - Proper `Crucible.Context` handling with artifacts and metrics storage
  - Stage completion tracking with `mark_stage_complete/2`
  - Support for all hedging strategies through IR configuration
  - Comprehensive error handling and validation
- **Enhanced SVG Logo**: Updated `assets/crucible_hedging.svg` with speed-themed racing design featuring parallel paths and finish line visualization
- **Configuration Management**: Added `config/config.exs` to disable CrucibleFramework.Repo (hedging doesn't need database persistence)
- **Documentation**: Added comprehensive documentation in `docs/20251225/`:
  - `current_state.md` - Complete module inventory and architecture documentation
  - `gaps.md` - Gap analysis and future improvements
  - `implementation_prompt.md` - Detailed implementation guide

### Changed
- Updated `crucible_ir` dependency from `~> 0.1.1` to `~> 0.2.0`
- Added `crucible_framework ~> 0.4.0` dependency for Stage behaviour support
- Enhanced race condition handling in core hedging logic with monotonic completion ordering
- Improved code quality with Credo integration
- Updated README.md with Crucible Framework integration examples

### Fixed
- Race condition in `find_first_result/1` by using both completion time and monotonic completion order
- Metrics calculation edge cases for empty latency lists
- Multi-level hedging pending task updates
- Code style improvements for Credo compliance
- Enhanced test reliability with `supertester` for proper isolation

### Dependencies
- Added `crucible_framework ~> 0.4.0` for pipeline integration
- Added `ecto_sql ~> 3.11` (optional, for framework compatibility)
- Added `postgrex >= 0.0.0` (optional, for framework compatibility)
- Added `supertester ~> 0.3.1` for improved test isolation
- Added `stream_data ~> 1.0` for property-based testing support
- Added `credo ~> 1.7` for code quality analysis

## [0.2.1] - 2025-11-26 (unreleased)

### Added
- **CrucibleIR Integration**: Added dependency on `crucible_ir ~> 0.1.1` for unified configuration
- **Pipeline Stage Interface**: New `CrucibleHedging.Stage` module implementing pipeline stage pattern
  - Accepts `CrucibleIR.Reliability.Hedging` configuration from experiment context
  - Provides `run/2` and `describe/1` functions for pipeline integration
  - Supports all hedging strategies through IR configuration
  - Returns structured context with results and metadata
- **IR Config Helper**: New `from_ir_config/1` function to convert IR structs to keyword options
- **Strategy Options Mapping**: Support for strategy-specific options from IR config options map
- **Comprehensive Stage Tests**: Full test coverage for Stage module with all strategies

### Enhanced
- Main `CrucibleHedging` module now supports IR config conversion
- Stage module provides detailed metadata including strategy used
- Error handling for missing or invalid IR configurations
- Documentation with IR config usage examples

### Documentation
- Added Stage usage examples to README
- Documented IR config integration patterns
- Added docstrings for all new public functions

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
