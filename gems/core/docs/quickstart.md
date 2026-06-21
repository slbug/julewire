# Quickstart

Start with one configured output:

```ruby
Julewire.configure do |config|
  config.destinations.use(:default, output: $stdout)
end

Julewire.emit(message: "hello")
```

By default, records are encoded as newline-delimited JSON.

## Point Records

`Julewire.emit` writes an immediate point record:

```ruby
Julewire.emit(
  severity: :info,
  event: "customer.charged",
  message: "charged customer",
  payload: { amount_cents: 1200 }
)
```

The shorthand form is useful for scripts:

```ruby
Julewire.emit("starting import")
Julewire.warn("retrying import", attempt: 3)
```

Known record keywords stay at the record top level: `timestamp`, `severity`,
`kind`, `event`, `message`, `logger`, `source`, `execution`, `context`,
`carry`, `neutral`, `attributes`, `labels`, `payload`, `metrics`, and `error`.
Other fields are folded into `payload`. Explicit `payload` keys win over folded
fields when they collide.

For expensive low-level payloads, put the severity in the eager fields and
build the rest lazily:

```ruby
Julewire.emit(severity: :debug) do
  { message: "expanded import state", payload: expensive_snapshot }
end
```

The block is not called when the eager severity is below the configured level.
If eager severity is present, it is authoritative; a block cannot upgrade or
downgrade it. If eager severity is absent, the block may provide severity, but
the block must run before core can apply the level check. Severity helpers use
the eager-severity rule:

```ruby
Julewire.debug { { message: "expanded import state", payload: expensive_snapshot } }
Julewire.warn("retrying")
```

`emit` returns `nil`. Use configured outputs, callbacks, and `Julewire.health`
for observation.

## Executions and Summaries

Use `with_execution` around work that has a beginning and an end:

```ruby
Julewire.with_execution(type: :operation, id: "op-1") do
  Julewire.context.add(tenant_id: "tenant-1")
  Julewire.summary.add(plan: "pro")

  Julewire.emit(message: "doing work")
end
```

Context fields appear on point records and summaries. Summary fields appear only
on the final summary. `with_execution` emits one summary record by default on
completion or failure.

Nested executions are allowed. Each level gets its own summary, and point
records include cheap parent/root/depth metadata. Processors can use the
explicit lineage accessor when they need the bounded ancestor chain.

## No Output Means No-Op

This is valid:

```ruby
Julewire.configure do |config|
  config.destinations.clear
end
```

With no destinations, core does not build, process, format, or write records. It
only increments `health[:pipeline][:counts][:no_output_dropped]`. This is useful
in tests and in deployments where custom code owns output setup.

## The Mental Model

Think of core as:

```text
emit -> normalize -> processors -> destination(formatter -> encoder -> output)
```

Processors own neutral policy and enrichment. A destination owns the final
formatter/output path. Its formatter sees an immutable processed
`Julewire::Record` and returns a payload object; its encoder turns that
payload into the output string.

For field placement, use this rule:

| Field bag | Best for |
| --- | --- |
| `context` | queryable facts copied onto point records and summaries |
| `carry` | propagation metadata for integrations and custom formatters |
| `neutral` | provider-neutral facts read by formatters |
| `attributes` | integration namespaces and application metadata |
| `summary` | final-only counters, timings, and completion facts |
| `labels` | operator-safe routing/grouping metadata |
| `metrics` | numeric measurements such as duration |

Custom destination objects own async output, files, fanout, batching, retries,
and delivery policy:

```text
emit -> normalize -> processors -> custom destination
```

Core stays synchronous. Processors and direct destination formatters run on the
emitting thread. Custom destinations own their own serialization and transport
work.
