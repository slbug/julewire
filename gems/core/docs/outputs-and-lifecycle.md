# Outputs and Lifecycle

Outputs are stdout-ish:

```ruby
output.write(string)
```

Optional methods:

```ruby
output.flush
output.close
```

Lifecycle hooks are no-argument output hooks:

```ruby
flush
close
```

Runtime timeouts provide one carried deadline while core walks destinations.
Core cannot interrupt arbitrary blocking output code, and plain outputs do not
receive the timeout value. After the first attempted resource, core skips later
resources when the deadline is already exhausted. Custom destination objects own
timeout-aware drain, retry, reopen, and rotation policy.

## Boundary

Core is synchronous output only:

```text
emit -> normalize -> processors -> destination(formatter -> encoder -> output)
```

Destinations format an immutable `Julewire::Record` into a payload object.
Encoders turn direct destination payload objects into strings. Outputs receive
strings.

Processors may intentionally return `:drop`. Core counts those records in
`health[:pipeline][:counts][:processor_dropped]`; processor failures are counted
separately as `processor_error`.

Async queues, files, fanout appenders, batching, retries, acknowledgements,
reopen, rotation, shutdown hooks, and delivery policy belong in custom
destination objects. Core keeps enough output lifecycle to be useful for
`$stdout`, tests, and small scripts.

## No Output

An empty destination registry means an intentional no-output pipeline. Records
are dropped before normalization, processors, and formatting. Core increments
`health[:pipeline][:counts][:no_output_dropped]` so accidental no-output mode is
visible in health.

Application and integration code should usually make no-output mode
explicit instead of inheriting it silently. Core keeps it available for tests,
scripts, and deliberate dry runs.

## Ownership

Outputs are caller-owned by default.

```ruby
Julewire.configure do |config|
  file = File.open("log/julewire.log", "a")
  config.destinations.use(:default, output: file, close_output: true)
end
```

Use `close_output = true` for files or sockets core should close. Keep it false
for `$stdout`, caller-owned loggers, and shared objects.

## Synchronous Output

Core wraps direct outputs with one mutex. Concurrent emitters do not interleave
individual encoded records, but a slow sink blocks the emitting thread.

A synchronous output failure is contained. The destination records output
failure counters and calls `on_failure`. Core does not retry, back off, or
short-circuit broken outputs; those are destination policies.

Plain `write` outputs and custom destination `emit` calls are optimistic: any
non-raising result except `false` is accepted. A plain `false` is treated as a
rejected write or destination rejection and counted as destination loss. Custom
destination objects still own richer backpressure, retry, and partial acceptance
semantics.

## Destinations

Direct core output is always configured through destinations:

```text
emit -> normalize -> processors -> :default(formatter -> encoder -> output)
```

Multiple destinations are explicit:

```ruby
Julewire.configure do |config|
  config.destinations.use(
    :json_stdout,
    formatter: Julewire::RecordFormatter.new,
    encoder: Julewire::JsonEncoder.new,
    output: $stdout
  )

  config.destinations.use(
    :debug,
    formatter: Julewire::RecordFormatter.new,
    encoder: Julewire::JsonEncoder.new,
    output: File.open("log/debug.json", "a"),
    close_output: true
  )
end
```

Custom destinations may add a destination object directly with
`config.destinations.add(destination)`. That object receives the same immutable
processed `Julewire::Record` and owns its own formatter, serialization,
and delivery contract.

Multiple destinations receive the same immutable processed record object.
Hashes, arrays, and copied strings inside the record are frozen; arbitrary app
objects inside fields are not deep-frozen. Formatters are read-only mappers.
Mutation belongs in processors.

Destinations cannot share the same raw output object. Core sync output keeps one
mutex per destination and rejects shared sinks instead of guessing fanout
semantics. Use a custom destination when same-format multi-sink writes need
shared locking, async, buffering, rotation, batching, or fanout policy.

## Lifecycle

`Julewire.flush` and `Julewire.close` call the active pipeline's destinations
in order.

`flush` and `close` use `config.pipeline_close_timeout` when no timeout is
provided. A caller-provided `nil` timeout means unbounded wait. This timeout
does not make direct output calls interruptible; it only bounds whether core
attempts later destinations after a previous lifecycle call returns.

`close` is terminal for the active runtime state. If output close fails or times
out, `Julewire.close` returns `false`, but later emits still drop as
`runtime_closed` until the next `configure` or `reset!`.

`Julewire.after_fork!` resets process-local counters, failure snapshots,
current context, warning state, and mutexes inherited from the parent process.
It also forwards `after_fork!` to destinations and outputs that implement it,
then runs integration after-fork hooks registered through core. File, socket,
queue, and async transports should reopen worker-local resources from their
destination or output `after_fork!` method.

Core does not install an `at_exit` hook. Small scripts should call close from
their own shutdown path:

```ruby
begin
  # work
ensure
  Julewire.close(timeout: 1)
end
```

Applications and integration code should install their own shutdown hooks with
finite timeouts.

## Health

Core health is a pipeline snapshot, not a delivery receipt.

Preferred alert fields:

- top-level `status`, `closed`, `generation`, `counts`, and `last_failure`
- `pipeline.configured`, `pipeline.counts`, and `pipeline.last_failure`
- `destinations.*.counts`
- `destinations.*.last_failure`
- `destinations.*.last_loss`

Destination `counts` includes direct-output loss counters such as formatter
failures, encoding failures, record-size drops, output exceptions, and output
rejections. Custom destination objects own their own queue, file, fanout,
retry, delivery, and lifecycle health fields.

Destination loss belongs to the active pipeline generation. Any destination
with non-zero active-generation loss is degraded until reconfigure or reset.
`destinations.*.last_loss` gives the latest safe loss reason and record
coordinates without exposing raw payloads or exception messages.

Integrations own concrete metric names. Core keeps health paths explicit for
contract tests, but does not prescribe external metrics mapping.

## Loss Model

Core is best effort:

- no output drops records intentionally
- level filtering drops records before normalization when eager severity is known
- oversized encoded records are dropped
- formatter and encoder failures drop the affected record
- output exceptions and `false` writes drop the affected record
- post-close emits are dropped and counted at runtime level

Core does not provide durable storage. Custom destinations that need delivery
semantics own batching, retry, acknowledgement, and shutdown drain behavior.
