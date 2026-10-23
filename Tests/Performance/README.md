# Capture profiling

`HierarchyProfiler.m` and `ClientStages.m` are measurement-only observers; they
are not linked into the application. Record matched Full/Hybrid scenes, preserve
all samples, and compare equal node/image coverage. Readiness is distinct from
GPU presentation. Do not run build jobs during timing measurements.

`compare_captures.py records.json --output comparison.json` summarizes a JSON
array of `{case, metrics, coverage}` records. `case` is `before` or `after`; timing
keys are `tree_ready_ms`, `working_preview_ready_ms`, `preview_ready_ms`, and
`full_complete_ms`. It fails when coverage differs. Run its unit tests with
`python3 Tests/Performance/test_compare_captures.py`.

`Results/20261023` preserves measurements of the predecessor implementation,
not a new benchmark of this fork. The old MCP-dependent launch/measurement
orchestrator is deliberately not included. `ProbeAppDelegate.swift` and
`wire_client.m` remain available for controlled protocol and GUI checks.
