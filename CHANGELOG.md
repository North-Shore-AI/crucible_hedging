# Changelog

All notable changes to this project will be documented in this file.

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
