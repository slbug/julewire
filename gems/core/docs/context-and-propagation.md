# Context and Propagation

Context is ambient application data for the current execution/fiber. Carry is
small propagated integration/correlation data. Attributes are emitted
record-local data for integrations and formatters, but are not propagated.
Summary is final-only data for the current execution.

```ruby
Julewire.context.add(request_id: "req-1")
Julewire.carry.add(http: { request_headers: { traceparent: "..." } })
Julewire.attributes.add(my_app: { shard: "a" })

Julewire.with_execution(type: :job, id: "job-1", labels: { worker: "billing" }) do
  Julewire.context.add(worker: "background")
  Julewire.attributes.add(runtime: { queue: "default" })
  Julewire.summary.increment(:records_seen)
  Julewire.measure(:upstream) { call_upstream }
  Julewire.summary.append(:warnings, "slow upstream")

  Julewire.emit(message: "processed")
end
```

Context appears on point logs and summaries. Carry is available to processors,
formatters, and propagation envelopes, but the default formatter does not write
it to JSON output. Integration-specific attribute namespaces appear on emitted
records and summaries. Neutral fields coordinate formatters through the record's
`neutral` section and are stripped by the default formatter. Use
`Julewire.summary.add_attributes` to add attributes to a final summary. Summary
payload data appears only on the final summary. Attributes and summary data are
never propagated.

Nested executions inherit current attributes and neutral fields by default so
in-request child operations keep formatter coordination fields. Integrations
that restore a remote unit of work, such as a background job, can start the
execution with `inherit_attributes: false` and provide only that unit's fields.
Execution-level `labels:` apply to point records and the final summary for that
execution. Per-record labels can still override them.

## Merge Semantics

Nested `attributes` are deep-merged. This lets integrations add their own
namespaces without replacing each other.

`context`, `carry`, and `labels` merge at the top level on a record.
When context or carry overlays are stacked with `with`, an overlapping top-level
key replaces that whole value for lookups, snapshots, and emitted records.

Summary helpers have their own merge rules: `summary.add_attributes` deep-merges
attributes, while `summary.add` stores summary payload fields by key.

If you accept the block argument from `with_execution`, it is a read-only
execution view. Scalar execution fields are captured when the view is created;
field sections such as context, carry, and summary are materialized lazily on
first read. Mutating the live execution goes through `Julewire.context`,
`Julewire.carry`, `Julewire.attributes`, and `Julewire.summary`.

Deferred execution handles are not thread-safe mutation surfaces. If an
integration shares a handle across threads, it must serialize calls that add or
overlay context, carry, attributes, labels, or summary fields.

Ambient context is fiber-local. Applications that reuse fibers outside a
Julewire execution scope should overwrite or clear context before unrelated work
uses the same fiber.

## Context Helpers

```ruby
Julewire.context.add(user_id: "user-1")

Julewire.context.with(order_id: "order-1") do
  Julewire.emit(message: "inside order")
end

Julewire.context[:user_id]
```

Public helpers accept string or symbol keys and normalize strings to symbols
when data enters core. After that boundary, use symbol keys.

Runtime helpers are best effort. Non-hash positional values are captured under
`:value` instead of raising from application code.

## Carry Helpers

```ruby
Julewire.carry.add(http: { request_headers: { traceparent: "..." } })

Julewire.carry.with(worker: { queue: "critical" }) do
  Julewire.emit(message: "inside worker")
end

Julewire.carry.delete(:http, :request_headers, :authorization)

Julewire.carry.without(:http, :request_headers, :traceparent) do
  Julewire.emit(message: "without trace carry")
end

Julewire.carry[:http]
```

Carry is for small facts that integrations and formatters need on every record
and across propagation boundaries. It is not application log content, a privacy
boundary, or summary storage. Avoid large blobs unless a processor policy will
handle them before formatting.

`carry.delete` is persistent until the same path is added again with
`carry.add`. That delete masks scoped `carry.with` overlays too. Use
`carry.without` for a temporary block-only mask.

## Summary Helpers

```ruby
Julewire.summary.add(plan: "pro")
Julewire.summary.increment(:upstream_calls)
Julewire.measure(:upstream) { call_upstream }
Julewire.summary.increment_attribute(:active_job, :continuation_steps_completed)
Julewire.summary.append(:warnings, "slow upstream")
```

`Julewire.summary.active?` reports whether the current fiber has a live
execution scope. `add`, `increment`, and `append` are strict: they raise
`Julewire::Core::Execution::NoCurrentError` outside `with_execution` instead of
silently dropping summary data.

`append` is non-raising for normal summary values:

- missing key becomes `[value]`
- array gets appended
- scalar becomes `[existing, value]`

`increment` adds numeric payload values normally. `increment_attribute`
increments nested summary attributes by path. If a key already holds
non-numeric summary data, core preserves the existing value and appends the
increment using the same array conversion rule.

`Julewire.measure(:upstream) { ... }` returns the block value, increments
`payload.upstream_count`, and accumulates elapsed milliseconds in
`metrics.upstream_duration_ms`. It records the timing even when the measured
block raises.

Use `Julewire.measure_start(:upstream)` when the measured work cannot fit in a
block. It returns an idempotent handle; call `finish` once the work is done.

Logging should not crash the app, but core also should not silently throw away
surprising data.

Summary records default to `source: "julewire"` and
`event: "#{type}.completed"`. Caller code can override that shape:

```ruby
Julewire.with_execution(
  type: :operation,
  summary_source: "app",
  summary_event: "operation.completed"
) do
  Julewire.summary.add(status: 200)
end
```

Error summaries emit with `severity: :error` unless the error path supplies an
explicit severity. Successful summaries use `summary_severity:` when set,
otherwise they use normal severity defaults.

## Current Execution

```ruby
execution = Julewire.current_execution
execution.context_hash
execution.carry_hash
execution.summary_hash
```

`current_execution?` is the cheap predicate. `current_execution` returns a
read-only execution view with lazily materialized field sections. Mutating the
live execution goes through `Julewire.context`, `Julewire.carry`,
`Julewire.attributes`, and `Julewire.summary`.

## Deferred Execution Handles

Integrations that start work in one place and finish it later can use an
explicit handle:

```ruby
handle = Julewire.start_execution(type: :request, id: "req-1")

status, headers, body = handle.run do
  app.call(env)
end

body = ContextRestoringBody.new(body, handle) do
  handle.finish(reason: :closed, fields: { status: status })
end
```

`finish` is idempotent. The first finish emits the summary; later close hooks
or timeout callbacks are no-ops. `run` restores the handle context and finishes
on exceptions, but successful deferred executions must call `finish` explicitly.
Finished summaries include a visible `julewire.completion` attribute with the
first finish reason.
Timeout summaries should say they timed out:

```ruby
handle.finish(reason: :timeout, fields: { completion_timeout_ms: 30_000 })
```

Use `handle.with_context` around late body iteration, callbacks, or stream
cleanup when those operations should inherit the original execution context.
This is an integration primitive; ordinary application code should prefer
`Julewire.with_execution`.

## Propagation Envelopes

```ruby
envelope = Julewire::Core::Propagation.capture

Julewire::Core::Propagation.restore(envelope) do
  Julewire.emit(message: "restored")
end
```

Propagation restores context, carry, and execution metadata into direct point
records and into the next execution scope. It does not propagate summary data.
Execution metadata is restored as ordinary execution fields. Use
`Julewire.with_execution(..., fields: { trace_id: "..." })` for custom
execution fields at the public API boundary.

Propagation serializes values through the core serializer. That means values
cross a log-safe boundary, not an object-identity boundary.

Core does not redact propagation envelopes. Do not put secrets in context or
carry unless your app or processor policy handles them.

By default, a new local execution started after restore gets a new local
lineage. At trusted boundaries where the remote execution should be the parent,
use `link_executions: true`:

```ruby
Julewire::Core::Propagation.restore(envelope, link_executions: true) do
  Julewire.with_execution(type: :job, id: "job-1") { perform_job }
end
```

Restoring an envelope is an explicit trust decision. Core validates shape and
caps inbound carrier bytes by default, but core does not authenticate who wrote
the carrier. At untrusted boundaries, extract only the carrier fields you
intentionally accept, apply any application spoofing/filter policy first, then
call `Carrier.restore` on that filtered carrier map.

## Flat Carriers

Adapters that cross a serialized boundary can put the propagation envelope into
a flat string carrier:

```ruby
headers = Julewire::Core::Propagation::Carrier.inject({})

Julewire::Core::Propagation::Carrier.restore(headers) do
  Julewire.emit(message: "restored from headers")
end
```

For inbound request headers, keep restoration explicit:

```ruby
trusted = filter_trusted_headers(request.headers)
Julewire::Core::Propagation::Carrier.restore(trusted) do
  handle_request
end
```

Inbound extraction and restore default to `Carrier::DEFAULT_MAX_BYTES`; pass
`max_bytes: nil` only for a trusted unbounded carrier. Use `max_bytes:` on
injection when the carrier target has stricter size constraints:

```ruby
headers = Julewire::Core::Propagation::Carrier.inject({}, max_bytes: 8 * 1024)
# => nil when the serialized carrier is too large; the carrier key is removed
```

The default carrier key is `"julewire"`. Carriers are intentionally
provider-neutral: core stores only the Julewire propagation envelope. External
header conventions stay outside core.

Carriers are transport metadata. They may become visible if an application logs
full carrier maps. Keep integrations responsible for deciding which external
metadata to mirror into carry, and keep normal processors in the destination
path for emitted records.

## Thread and Fiber Wrappers

Raw threads and raw fibers do not magically inherit Julewire context. Use the
wrappers when you want propagation:

```ruby
Julewire.context.add(request_id: "req-1")

thread = Julewire.thread do
  Julewire.emit(message: "from thread")
end

thread.join
```

```ruby
fiber = Julewire.fiber do
  Julewire.emit(message: "from fiber")
end

fiber.resume
```

Each wrapper captures the current propagation envelope once and restores it
around the block.

Thread and fiber wrappers use a local snapshot, not the serialized propagation
envelope. Ruby values keep their local shape across those same-process
boundaries. `Propagation.capture` remains the serialized/log-safe envelope for
cross-runtime and external transport boundaries.

Restored execution metadata is available to direct point logs when no live
execution scope is already active. A live scope wins over the restored snapshot.
The snapshot is also inherited by the next `with_execution` opened inside the
wrapper. It is not a live execution scope by itself, so `Julewire.summary` is
unavailable unless the wrapped code opens a new `with_execution`.

## Remote Runtime Hooks

Core keeps a small remote-envelope hook so bridge code can send normalized
input, context, and scope snapshots back to another runtime. The receiving
runtime's configuration, processors, level, destinations, labels, and outputs
remain authoritative.

Inside a remote runtime, `Julewire.reset!` is local to that runtime storage. It
does not reset another runtime's configuration, destinations, or health
counters.

## Reset Semantics

`Julewire.reset!` clears:

- active configuration
- current fiber context store
- the old active pipeline/output lifecycle
- live runtime post-close drop and callback-failure state

`health[:counts]` is different: it is monotonic for the current runtime object
and survives `reset!`. Use it for process-lifetime runtime lifecycle scrapes.

Other long-lived threads/fibers keep their own context stores until they reset
or exit. Long-lived workers should reset or replace per-execution context on
each unit of work.

Main runtime context uses storage on the current Ruby fiber. Non-main ractors
use thread-local storage because bridge runtimes are ractor-local.
