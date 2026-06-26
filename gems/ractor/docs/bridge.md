# Bridge

`julewire-ractor` adds two facade methods:

- `Julewire.enable_experimental_ractor!`
- `Julewire.ractor`

The opt-in is deliberate. Ractor support is Ruby-version-sensitive, bridge
emits use an unbounded port queue, and the bridge is outside the stable core
application API. Core documents the narrow Bridge SPI used by this gem.

## Flow

```text
child ractor emit
  -> remote runtime serializes input, context, carry, and scope
  -> Ractor::Port message
  -> parent bridge thread
  -> bridge reconstructs a core scope snapshot
  -> parent runtime emit_envelope
  -> core processors, destinations, formatter, encoder, output
```

The parent runtime owns all policy. The child does not install configuration,
outputs, processors, labels, or event definitions. Parent static labels still
apply to records emitted by the child.

Values are serialized before crossing the ractor boundary. Parent-side
processors see log-safe scalar values rather than the child object's original
identity or class.

The serialized envelope is a ractor concern. Core keeps only the narrow
`emit_envelope` hook that accepts already-extracted input, context, carry, and
a scope snapshot. Payload parsing and scope reconstruction stay in this gem.
That hook is parent-runtime SPI; the bridge marks ractor wire data as owned, and
the child `RemoteRuntime` exposes the normal facade emit methods instead of a
detached-envelope API.

## Available in Child

`Julewire.emit` sends a fire-and-forget message to the parent bridge.
Child-side emits serialize and cross the ractor port before the parent runtime
applies its level threshold.

Child-side send loss is visible inside the child runtime:

```ruby
Julewire::Ractor.child_stats
Julewire::Ractor.reset_child_stats!
```

These counters cover child-to-parent port sends, lifecycle requests, request
timeouts, and the last local send error class. Parent bridge health still lives
at `Julewire::Ractor.health`.

Integration code can call `RuntimeLocator.current.emit_without_level` inside
the child when it has already applied its own level gate.

`Julewire.with_execution`, `Julewire.context`, `Julewire.carry`,
`Julewire.attributes`, and `Julewire.summary` work against the child-local
context store. Summary records are sent to the parent when execution scopes
finish.

`Julewire.flush` sends a request/reply message to the parent bridge. The default
remote request timeout is one second. `timeout: nil` remains unbounded.

`Julewire.reset!` clears only the child-local context store.

## Parent Only

- `Julewire.configure`
- `Julewire.config`
- `Julewire.labels`
- `Julewire.health`
- `Julewire.close`

These belong to the parent runtime.

## Health

Bridge health is available through:

```ruby
Julewire::Ractor.health
```

It reports bridge thread counts, received message count, and the last bridge
thread error class. It is diagnostic state, not a delivery guarantee.

## Ractor Destination

`julewire-ractor` can make the normal `:default` destination kind ractor-backed:

```ruby
Julewire::Ractor.enable_default_destination_workers!

Julewire.configure do |config|
  config.destinations.use(:default, output: MyRactorCopyableOutput.new)
end
```

It also registers `:ractor` for additional ractor-backed destinations.

The parent pipeline still normalizes, processes, and freezes records
synchronously. The destination then sends each immutable record to a worker
ractor. The worker owns formatter, encoder, byte-limit checks, and output
writes.

The destination has a bounded parent-side in-flight queue. When `max_queue` is
full, new records are dropped and counted in destination health. `flush` sends a
request to the worker and waits for all earlier records to finish. `close`
flushes or closes the worker-owned output and stops the worker.

Unlike direct core destinations, ractor-backed destinations treat
`flush(timeout: nil)` and `close(timeout: nil)` as the configured request timeout
instead of an unbounded wait. Worker ractors can die or stop replying; the parent
must not park forever while draining diagnostics.

Formatter, encoder, and output must be ractor-copyable or shareable. Avoid
singleton-method/proc-backed output objects; plain class instances with
ractor-safe state are the intended shape.
Record payload values sent through `Julewire::Ractor::Destination` must also be
ractor-copyable or shareable. Non-copyable values are dropped at the parent-side
send boundary and counted as `send_error`.

Use `Julewire::Ractor::Fanout` when one core destination should fan out to
multiple ractor-backed destination workers:

```ruby
config.destinations.add(
  Julewire::Ractor.fanout(
    destinations: [
      { name: :stdout, output: $stdout },
      { name: :audit, output: audit_io }
    ]
  )
)
```

The parent pipeline still processes once. Each fanout child formats, encodes,
and writes in its own destination worker.

## Raw Ractors

Raw `Ractor.new` does not install the bridge. Use `Julewire.ractor` when child
code needs Julewire facade calls to reach the parent runtime.

## Forking

Do not fork a process with live Julewire ractor bridges. After a process fork,
core calls the ractor integration after-fork hook and clears inherited bridge
thread health. Create new ractors in the worker process after fork.

## Runtime Promise

Inside `Julewire.ractor`, `Julewire.emit` is best-effort fire-and-forget. Use
`Julewire.flush` when the child wants to ask the parent bridge to drain.

The bridge uses Ruby's ractor message-passing model and an unbounded
`Ractor::Port`. It should not be used as a reliable inter-ractor queue.
