# Semantic Logger Transport

The adapter uses Semantic Logger as transport only.

It does not use Semantic Logger's JSON formatter for Julewire records because
that formatter emits Semantic Logger's schema. Julewire formatters already own
the output shape.

## Destination Path

```text
Julewire formatter -> Julewire encoder -> Semantic Logger exact formatter -> IO
```

This uses the adapter destination. The destination maps the record with the
configured formatter, encodes the formatter result with Julewire's encoder, then
hands the encoded payload string to Semantic Logger. The exact formatter
preserves that string shape for appenders.

```ruby
class LogShape
  def call(record)
    {
      level: record.fetch(:severity),
      message: record.fetch(:message),
      labels: record.fetch(:labels),
      payload: record.fetch(:payload)
    }
  end
end

Julewire.configure do |config|
  config.destinations.use(
    :semantic_logger,
    formatter: LogShape.new,
    io: $stdout,
    async: true
  )
end
```

Core passes a frozen, normalized, symbol-key record to the destination
formatter. The adapter formatter returns the output object; the destination
encoder turns that object into the final JSON payload.

## Design

Semantic Logger fits as transport if Julewire owns record mapping.

Semantic Logger does not fit as the default formatter unless Julewire accepts
Semantic Logger's log schema.

## Verified Paths

Verified paths:

- custom destination object formatter -> Julewire-encoded JSON line through Semantic Logger
- async Semantic Logger appender -> flush drains queued entries
- file appender -> writes exact Julewire payload JSON lines
- multiple appenders -> multi-appender output without Julewire owning transport code
- health -> appender type, async queue state, file metadata, child appenders,
  transport warnings

## Metric Mapping

The adapter owns metric names because queue, file, and appender behavior is
transport-specific. One practical mapping is:

| Health path | Metric name |
| --- | --- |
| `counts.*` | `julewire_runtime_total{event}` |
| `pipeline.counts.*` | `julewire_pipeline_total{event}` |
| `destinations.*.counts.*` | `julewire_destination_total{destination,event}` |
| `destinations.*.last_loss.reason` | `julewire_destination_last_loss{destination,reason}` |
| `destinations.*.transport.counts.*` | `julewire_semantic_logger_transport_total{destination,event}` |
| `destinations.*.transport.appender.queue_size` | `julewire_semantic_logger_queue_size{destination}` |
| `destinations.*.transport.appender.max_queue_size` | `julewire_semantic_logger_queue_capacity{destination}` |
| `destinations.*.transport.warnings.*` | `julewire_semantic_logger_warning{destination,reason}` |

Extensions should treat core health paths as inputs, not as a global metrics
schema.

Observed behavior:

- Semantic Logger's IO appender appends the final newline, so this adapter strips
  one trailing newline when it receives an already encoded string.
- Output-shaped severity values such as `"INFO"` should not be treated as
  Semantic Logger levels. The transport maps only known levels and otherwise
  uses `:info`. Julewire `:unknown` maps to Semantic Logger `:fatal`.
- bounded Semantic Logger async queues block producers when full; the adapter
  reports this as a lifecycle warning.
- `max_queue_size: -1` is unbounded queueing; the adapter reports that as a
  lifecycle warning.
- sync multi-appender output writes through all child appenders on the caller
  thread; the adapter reports that as a lifecycle warning when more than one
  appender is configured and `async: false`.
- `flush(timeout:)`, `close(timeout:)`, and `reopen(timeout:)` accept Julewire's
  lifecycle keyword for the destination contract, but Semantic Logger appenders
  own the actual blocking behavior. The timeout is advisory for this adapter.
- `after_fork!` delegates to `reopen`, matching Semantic Logger's fork contract:
  async appender queues and worker threads are recreated in the child process.

Architecture implication:

- using Semantic Logger as a destination transport is clean
- using Semantic Logger as the record schema is not
- core formatters should return objects; encoders own final serialization
- core should not grow async/file/multi-appender transport primitives
