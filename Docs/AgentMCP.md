# Agent interface

Open Lookin and configure an MCP client with the Streamable HTTP endpoint
`http://127.0.0.1:47199/mcp`. **Lookin → MCP for Agents…** shows status and copies
the URL. Only one Lookin instance can own the port. The server binds to IPv4
loopback, validates Host and Origin, and exposes no app mutation or arbitrary
method-execution tool.

This is a new implementation; no provider or lifecycle code from the earlier
MCP fork is used. `AgentBridge` uses the official
[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) and its stateless
HTTP transport. The SDK revision is pinned because upstream includes a
NetworkTransport fix required by Swift 6.3.3. Supported protocol revisions follow
that SDK (2025-03-26, 2025-06-18, 2025-11-25); the redesigned 2026 protocol is not
advertised. There are no SSE subscriptions or transport session IDs. Independent
request handlers prevent JSON-RPC ID collisions between clients.

## Tools

| Tool | Purpose |
| --- | --- |
| `list_apps` | Discover running inspectable apps and exact connection references. |
| `connect_app(appRef)` | Select a discovered connection and capture its hierarchy in the GUI. |
| `get_snapshot` | Read a bounded flat tree with parent/child references and pagination; optionally refresh. |
| `find_nodes(query)` | Search class or available text and return bounded matches. |
| `get_node(ref)` | Load a node's properties, constraints and event handlers on demand. |
| `get_image(ref)` | Load a native MCP PNG, including children by default. |

Start with `list_apps`, then `connect_app`, then `get_snapshot`. Tree results
default to depth 4 and 100 nodes; at most 300 nodes are returned per request.
Continue using `nextOffset`, the same `snapshotId`, root and depth. Child lists
are capped at 200 with explicit counts and truncation flags. Node summaries and
attribute values are bounded. Excessive detailed responses fail with a smaller
scope recommendation rather than silently returning an incomplete JSON document.

Each node `ref` belongs to one snapshot. A refresh, reconnect or GUI hierarchy
replacement invalidates it. `stale_ref` and `stale_snapshot` require another
snapshot/search; an oid from an older capture is never silently rebound. All
clients share the GUI selection. A request holding a ref for another selection
fails instead of inspecting the wrong app.

Readiness reports distinguish available tree/preview, pending resources, complete
metadata and complete images. Interactive mode can be idle with a usable snapshot
and intentionally incomplete resources. Tree, attributes and PNG may be captured
at different times. `get_node` and `get_image` reject a hierarchy change during
their resource request. Text search covers summaries and already-loaded string
attributes; it does not promise an exhaustive search of unloaded metadata.

PNG preserves its original alpha. Images above 16 MiB or unavailable layers
return an actionable error. Attribute values include typed constraints and object
references where the referenced object belongs to the current tree.
For a physical leaf layer, the group PNG is also its isolated-layer PNG; the
tool reuses it when `includeChildren=false`.

## Connection and verification

For Xcode Run on devices or Simulator, enable [Xcode Integration](PhysicalDevices.md)
once and keep Debug executable and breakpoints enabled. Auto-Connect's environment
ready status alone does not prove Xcode inherited the loader.

`Scripts/test.py` includes official Swift MCP client interoperability, equal-ID
request isolation, Origin validation, deterministic port/launch retry regressions,
and client/server resource tests. `Tests/build_xcode_simulator_fixture.py` creates
an independent Xcode project without an embedded Lookin dependency for real Run
verification. The live agent regression script exercises all six tools against
a running fixture, including paging, invalid arguments and invalidation after refresh.
