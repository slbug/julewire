# Configuration

`Julewire.configure` is the only mutation path for runtime configuration:

```ruby
Julewire.configure do |config|
  config.level = :info
  config.destinations.use(
    :default,
    formatter: Julewire::RecordFormatter.new,
    output: $stdout,
    close_output: false
  )

  config.labels.add(service: "billing", env: "production")

  config.on_failure = ->(error, metadata) {
    warn("julewire failure phase=#{metadata[:phase]} error=#{error.class}")
  }

  config.on_drop = ->(reason, metadata) {
    warn("julewire dropped reason=#{reason} phase=#{metadata[:phase]}")
  }
end
```

## Core Settings

| Setting | Meaning |
| --- | --- |
| `level` | Global minimum severity. Defaults to `:debug`. |
| `pipeline_close_timeout` | Default timeout for pipeline close. Defaults to `1`. |
| `emit_non_standard_exception_summaries` | Emit summaries while unwinding `SystemExit`/signals. Defaults to `false`. |
| `error_backtrace_lines` | Exception backtrace line cap. Defaults to `20`; set `0` to omit backtraces. |
| `labels` | Static labels merged into every record. |
| `processors` | Chain that mutates/enriches records before formatting. |
| `destinations` | Named formatter/encoder/output graph or custom destinations. |
| `on_failure` | Best-effort callback for contained core failures. |
| `on_drop` | Best-effort callback for operational drops after a record reaches destination/output handling. |

Timeout values must be `nil` or non-negative finite numerics.
`error_backtrace_lines` must be a non-negative integer.

`error_backtrace_lines` applies at core's error-shaping boundaries. When a
record enters core with an `Exception` under `error`, core builds the error hash
with that limit before the record is frozen. When a formatter/serializer later
sees an `Exception`, it applies the same limit while shaping it. Integrations
should pass real `Exception` objects or core-shaped error hashes; core also
trims `backtrace` fields on those error hashes at record ingress so a forgotten
adapter limit cannot leak a full stack by accident.

Async queues, files, fanout, batching, retries, and delivery policy belong in
custom destinations. Core owns sync destination writes only.

## Levels

Supported severities:

```ruby
debug info warn error fatal unknown
```

Core accepts symbols, strings, and stdlib `Logger::Severity` integers. String
and symbol names are case-insensitive.

Records with eager severity below `config.level` are dropped before context
lookup, processors, formatting, and output writes. For lazy `emit` blocks with
no eager severity, core evaluates the block first, then applies the level check
to the final record.

When `Julewire.emit` receives both a positional hash and keyword fields, keyword
fields win for duplicate top-level keys before record normalization. In lazy
emits, the block result wins over eager non-severity fields; an eager severity
from a severity helper such as `Julewire.warn` remains authoritative.

## Static Labels

```ruby
Julewire.configure do |config|
  config.labels.add(service: "billing")
  config.labels.remove(:debug_label)
  config.labels.clear
end
```

Labels follow the core field contract: public helpers accept string or symbol
keys and normalize strings to symbols at the boundary. Per-record labels
override configured static labels with the same symbol key.

Labels are meant for non-sensitive, low-cardinality dimensions such as service,
environment, shard, region, or runtime. Core may copy labels into internal
diagnostic records because labels are treated as operator-safe routing/grouping
metadata. Do not put PII, secrets, or high-cardinality payload data in labels.

## Processors

Processors run before destinations:

```ruby
Julewire.configure do |config|
  config.processors.use MyProcessor
  config.processors.use MyProcessorWithArgs, "constructor-arg", enabled: true
  config.processors.use EnrichmentProcessor, on_error: :fail_open
  config.processors.prepend FirstProcessor
  config.processors.use Julewire::Match.new { on(severity: :debug) { :drop } }
  config.processors.use :sampling, rate: 0.1
  config.processors.use do |draft|
    draft[:attributes][:app] = { source: "app" }
  end
end
```

Core ships no default policy processors. It does include small processor
helpers such as `Julewire::Match` and deterministic head sampling through the
registered `:sampling` processor. Redaction and enrichment belong in
processors. Output-specific shape belongs in destination formatters. Processors
are the mutation stage.

Processors receive the current `Julewire::RecordDraft`. Mutate the draft
directly. Return `:drop` to stop delivery or a different `Julewire::RecordDraft` to
replace the current draft; any other return value is ignored. Processors own
the draft until the final record boundary, so direct mutation is the normal hot
path:

```ruby
class AddTenantLabel
  def call(draft)
    tenant = draft.fetch(:context).fetch(:tenant_id, nil)
    return unless tenant

    draft[:labels][:tenant] = tenant
  end
end

Julewire.configure do |config|
  config.processors.prepend AddTenantLabel.new
end
```

The `:sampling` processor hashes a deterministic key and returns `:drop` for
unsampled records. By default it uses execution/root identifiers when present,
then `context.request_id`, then deterministic record fields. Pass `key:` to choose an
application-specific key:

```ruby
config.processors.use(
  :sampling,
  rate: 0.05,
  key: ->(draft) { draft.dig(:context, :tenant_id) }
)
```

Processor exceptions use the registration policy:

| `on_error` | Behavior |
| --- | --- |
| `:fail_closed` | Default. Emit a `julewire.processor_error` replacement record and stop the chain. |
| `:fail_open` | Record the failure, keep the current draft, and continue with later processors. |
| `:drop` | Record the failure and suppress the record. |

Public emit input remains defensive. The final immutable record boundary
validates the Julewire record shape before destinations see it.

Destination-local processors run after the global processor chain and before
one destination formats the record. Use them for sink-specific policy such as
audit-only enrichment or destination-only sampling:

```ruby
Julewire.configure do |config|
  config.destinations.use(:stdout, output: $stdout)
  config.destinations.use(
    :audit,
    output: audit_io,
    processors: [
      ->(draft) { draft[:labels][:sink] = "audit" }
    ]
  )
end
```

A destination-local drop or processor failure affects only that destination.

## Destinations

Direct destinations pair a formatter, encoder, and output:

```ruby
Julewire.configure do |config|
  config.destinations.use(
    :default,
    formatter: Julewire::RecordFormatter.new,
    encoder: Julewire::JsonEncoder.new,
    output: $stdout
  )
end
```

Integration gems may register destination kinds with adapter-specific options:

```ruby
Julewire.configure do |config|
  config.destinations.use(:provider_json, output: $stdout)
  config.destinations.use(:transport, formatter: formatter, io: $stdout)
end
```

For local human-readable output, pair the console formatter with the text
encoder:

```ruby
Julewire.configure do |config|
  config.destinations.use(
    :console,
    formatter: Julewire::ConsoleFormatter.new,
    encoder: Julewire::TextEncoder.new(color: $stdout.tty?),
    output: $stdout
  )
end
```

For a loud local console, `Julewire.punk!` replaces the named runtime's
destinations with the console formatter and the punk text theme:

```ruby
Julewire.punk!(color: $stdout.tty?)
```

For local containment drills, add `chaos: true`. It wraps the output with a
small chaos sink that occasionally raises, rejects, or stalls writes so the
runtime health path visibly degrades while application calls stay contained.

```ruby
Julewire.punk!(color: $stdout.tty?, chaos: true)
```

`Julewire.dev!` is the same core-local dev shape with a bounded in-memory tail
attached:

```ruby
tail = Julewire.dev!(chaos: true, tail: { capacity: 500 })
```

Additional destinations are explicit:

```ruby
Julewire.configure do |config|
  config.destinations.use(
    :json_stdout,
    formatter: Julewire::RecordFormatter.new,
    encoder: Julewire::JsonEncoder.new,
    output: $stdout
  )

  config.destinations.use(
    :debug_file,
    formatter: Julewire::RecordFormatter.new,
    encoder: Julewire::JsonEncoder.new,
    output: File.open("log/debug.json", "a"),
    close_output: true
  )
end
```

Destination options:

- `formatter`
- `encoder`
- `output`
- `close_output`
- `max_record_bytes` (defaults to `1 MiB`)
- `on_failure`
- `on_drop`
- `processors`

Extensions can also install an already-built destination object:

```ruby
config.destinations.add(MyDestination.new(name: :custom))
```

Custom destination objects must respond to `name`, `emit(record)`, `flush`,
`close`, and `health`.

`Julewire.configure` starts from the active configuration. To replace the output
graph in a later configure call, clear destinations first:

```ruby
Julewire.configure do |config|
  config.destinations.clear
  config.destinations.use(:default, output: $stdout)
end
```

## Split Pipelines

The top-level `Julewire` facade uses the default runtime. Use named runtimes
when one process needs separate pipeline policy, such as redacted stdout and a
locked-down audit sink:

```ruby
Julewire.runtime(:audit).configure do |config|
  config.destinations.use(:audit, output: audit_io)
end

Julewire.runtime(:audit).emit(message: "audit-only")
```

Named runtimes have their own configuration, processors, destinations, health,
and close/flush lifecycle. `Julewire.after_fork!` resets every known runtime.

Destinations receive the immutable processed `Julewire::Record`. Hashes,
arrays, and copied strings inside the record are frozen; arbitrary app objects
inside fields are not deep-frozen. Formatters must treat the record as read-only
and return a payload object. Encoders turn formatter payloads into strings
before writing to direct outputs. The default encoder is
`Julewire::JsonEncoder`, which applies Julewire serialization before
`JSON.generate`. A formatter that mutates frozen containers raises and is
handled as a formatter failure.

Destination callbacks inherit from the global callbacks unless overridden.

For reconfigure semantics, callback details, and other low-level knobs, see
[Advanced Configuration](advanced-configuration.md).

Calling `Julewire.emit` from callbacks may still run the nested emit, but nested
callback delivery is suppressed as callback recursion. Components that track
callback failures count the suppression.
