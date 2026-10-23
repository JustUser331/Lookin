# Coordinator resource regressions

Run `python3 Tests/coordinator_regressions.py` on macOS with Xcode command-line tools. The runner compiles the production coordinator against a deterministic fake transport. It verifies resource matching, deduplication, priorities, cancellation, stale versions, metadata/attributes merging and legacy replies.

The 1000-node case checks that a delivered batch is applied exactly once without scanning unrelated jobs. `--source-m` and `--benchmark-old-response` support an explicit before/after diagnostic; default regression mode always enforces the indexed lookup contract. These checks do not replace live GUI, MCP or device verification.
