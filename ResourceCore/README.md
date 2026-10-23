# Lookin Resource Core

The first Swift migration boundary is the resource scheduler's decision logic
and session state. The `LookinResourceCore` target depends only on Foundation. It receives immutable
job descriptions and returns a batch plan; it never reads a live view, layer,
archive, transport channel or GUI model.

`LKStaticAsyncUpdateManager` remains the Objective-C facade. It applies model
changes, subscribes to ReactiveObjC transport, resolves consumers and retains
the existing public selectors. UIKit/runtime invocation, exception handling,
bootstrap and `.lookin` coding remain in their existing modules.

The host links this package through the existing local `LookinMCP` product.
Xcode discovers the new target and generated Objective-C module automatically;
no source files need to be registered in the Xcode project.

## Verification

```sh
swift test --package-path ResourceCore -c release
python3 Tests/coordinator_regressions.py
```

The second command compiles and links the real Swift core into the existing
fake-transport coordinator harness. Its generation, cancellation, reentrancy,
resource matching, priorities and legacy checks exercise the production facade
and the production Swift implementation together.

`HC_PLANNER_TRACES=/path/to/results.json` records 500 deterministic scenarios.
Pass `--source-m /path/to/previous-coordinator.m` to collect the Objective-C
reference and compare the resulting wire tasks. No alternate implementation is
enabled in the shipping app.

`HC_PLANNER_BENCHMARK=1` measures the production facade's batch planning for
35 and 1,000 nodes with 10 warmup and 100 measured iterations per size.
This isolates scheduling CPU time; it does not measure capture or network time.

## Preview support

The separate `LookinPreviewSupport` target depends on AppKit. Each preview owns
a `PreviewImageCache` isolated to the main actor. Exact PNG bytes, including
color metadata, are the cache key. Equal resources share a read-only NSImage;
group/solo resources, wire payloads and exported PNG files remain separate.
Legacy archives containing NSImage objects retain their existing render path.

The cache retains at most 128 entries and 64 MiB of estimated bitmap plus PNG
storage. Large images still render at native resolution without cache retention.
This is a cache ownership budget, not a limit on all SceneKit/GPU memory. A new
snapshot clears the cache; Focus and expand/collapse keep it. Changed PNG bytes
cannot return a previous image, even when the OID is reused.

Visible planes retain their current image independently of LRU eviction. The
production selection logic is exercised by `python3 Tests/preview_image_cache_regressions.py`,
including group/solo, overview, hidden layers, invalidation and legacy NSImage.
