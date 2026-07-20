# Internals

This file is for contributors and extension authors who need the shape of the
machine without reading every class first.

## Runtime State

The runtime stores immutable snapshots of:

- configuration
- pipeline
- whether the active pipeline has been closed

Main-ractor hot-path reads use the current frozen runtime state without taking
a global runtime lock. State transitions replace that snapshot atomically;
configure and reset are additionally serialized with the configure mutex while
close may overlap them. The successful atomic transition owns the previous
pipeline lifecycle, so concurrent close/reset operations cannot close the same
pipeline twice. Health and counters use their own synchronization. Non-main
ractors use ractor-local runtime storage because they cannot touch the main
runtime object directly.

Configuration, reconfigure, reset, and close are state transitions. They should
stay boring and explicit.

Configure calls are serialized with a dedicated configure mutex. The staged
pipeline is built before runtime state is swapped. If runtime state changes
before a staged configure can swap in, the staged pipeline is closed and
configure fails.

Close is terminal for the active runtime state. Post-close emits are counted and
dropped before pipeline work. Reconfigure installs a fresh open pipeline.

## Pipeline

The normal emit path is:

```text
threshold precheck
record normalization
static labels
processors
destinations
formatter/encoder/output write per destination
```

Below-threshold records with eager severity are dropped before context lookup
and record building. Lazy `emit` blocks without eager severity are evaluated
first so block-provided severity can be checked correctly.

Pipeline counters are operational counters, not delivery guarantees.
Destination `output_accepted` means the configured output accepted the encoded
string according to core's output contract.

## Fields::FieldSet

`Fields::FieldSet` owns three invariants:

- defensive copying of hashes, arrays, and strings at trust boundaries
- cycle-safe duplication of those container graphs
- symbol-key normalization

Public ingress accepts string or symbol keys because JSON-style hashes and
Ruby-style hashes both happen in app code. Core normalizes those keys once at
the boundary and uses symbol keys internally so processors, destinations, and
extensions do not pay repeated equivalent-key scans.

## Value Readers

`Records::RawInput` reads app-facing emit input before record construction.
`Integration::Values::Read` extracts best-effort values from framework objects.
`Integration::Values::Shape` normalizes adapter-built hashes at framework
ingress. `Fields::FieldSet` owns public field-bag copying, merging, and key
normalization at application or framework ingress. Once data is owned,
`Integration::Protocol` and strict deep validation require recursively Symbol-
keyed hashes; cross-gem code does not repair String keys. `Fields::Lookup` is
for best-effort display reads with the exact requested key and returns `nil` for
unreadable inputs; it does not bridge Symbol/String key forms inside normalized
records. Presentation code that reads decoded wire payloads uses its separate
`wire_value` helper at that restore boundary.

## Context Storage

Main runtime context uses storage on the current Ruby fiber.

Raw fibers do not inherit parent context. Julewire wrappers capture and restore
propagation envelopes explicitly.

Non-main ractors use thread-local storage because concurrent-ruby local-variable
helpers are not Ractor-shareable.

## Destination Boundary

Core writes synchronously to configured outputs. Async queues, files, fanout,
batching, retries, acknowledgements, and delivery health live in
custom destination objects.

## Scheduling

Main-process diagnostics and framework integrations use the process-owned
`Scheduling::SharedScheduler` so they do not each keep a background timer
thread. Ractor integrations own their stdlib timeout threads because a worker
Ractor cannot access the main scheduler's concurrent-ruby objects.

## Remote Envelope Hook

Core keeps `Runtime#emit_envelope(input:, context:, attributes:, carry:, neutral:, scope:, enforce_level:, owned:)`
for bridge code. The bridge reconstructs the scope snapshot, and core rebuilds
a normal record from input, context, attributes, carry, neutral, and that
snapshot before emitting through the active pipeline. Bridges pass `owned: true`
only for Julewire-owned wire data. It is not a public application API.

## Emit Entrypoints

| Entrypoint | Caller | Level gate | Input ownership |
| --- | --- | --- | --- |
| `Runtime#emit` | application facade | yes | normalized by core |
| `Runtime#emit_without_level` | host-process integrations | no | normalized by core |
| `Integration::Facade.emit` | integration SPI | configurable | adapter-owned record hash |
| `Runtime#emit_envelope` | bridge SPI | configurable | detached, adapter-owned envelope |

## Field Stack Layers

Field stacks keep immutable layers plus versioned read caches. A layer without
a parent builds a direct snapshot from its own fields. A layer whose parent
already has a snapshot merges on top of that cached parent snapshot. Otherwise
it walks the unsnapshotted source chain back to the nearest cached ancestor and
then replays fields plus delete paths forward.

## Best-Effort Rule

Core may contain `StandardError` from its own logging path. It must not swallow
application exceptions from user code.

That rule is the line between "logging must not crash the app" and "debugging
must not hide the app's real exception".
