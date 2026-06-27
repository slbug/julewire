# Configuration

`julewire-semantic_logger` registers the `:semantic_logger` destination kind.

```ruby
Julewire.configure do |config|
  config.destinations.use(
    :semantic_logger,
    formatter: Julewire::RecordFormatter.new,
    io: $stdout
  )
end
```

## Destination Options

| Option | Meaning |
| --- | --- |
| `name:` | Destination name. Required. |
| `formatter:` | Julewire formatter object. Required. |
| `encoder:` | Julewire encoder object. Defaults to core JSON without a trailing newline. |
| `transport:` | Prebuilt `Julewire::SemanticLogger::Transport`. |
| `**transport_options` | Passed to `Transport.new` when `transport:` is omitted. |

The destination passes the immutable Julewire record to `formatter`, then hands
the formatter result through `encoder`. The transport receives the encoded
string. String formatter results are treated as already encoded and lose one
trailing newline when present.

## Transport Options

At least one appender target is required.

| Option | Default | Meaning |
| --- | --- | --- |
| `io:` | none | IO appender target such as `$stdout`. |
| `file_name:` | none | File appender target. |
| `appender:` | none | Existing Semantic Logger appender. |
| `appenders:` | none | Array of appender specs. |
| `async:` | `false` | Wrap the sink in `SemanticLogger::Appender::Async`. |
| `max_queue_size:` | `10_000` | Async queue size. `-1` means unbounded in Semantic Logger. |
| `batch:` | `nil` | Use Semantic Logger batch async processing when supported by the appender. `true` implies async output. |
| `batch_size:` | `300` | Batch size for batch-capable async appenders. |
| `batch_seconds:` | `5` | Maximum seconds between batch writes. |
| `non_blocking:` | `false` | Semantic Logger 5+ async drop mode. Raises on older Semantic Logger when set to a non-default value. |
| `dropped_message_report_seconds:` | `30` | Semantic Logger 5+ dropped-message report interval. Raises on older Semantic Logger when set to a non-default value. |
| `async_max_retries:` | `100` | Semantic Logger 5+ async worker retry limit. Raises on older Semantic Logger when set to a non-default value. |

Unknown transport options are passed to Semantic Logger appender construction.

## Appender Specs

Single stdout appender:

```ruby
config.destinations.use(
  :semantic_logger,
  formatter: Julewire::RecordFormatter.new,
  io: $stdout
)
```

Multiple appenders:

```ruby
config.destinations.use(
  :semantic_logger,
  formatter: Julewire::RecordFormatter.new,
  appenders: [
    { io: $stdout },
    { file_name: "log/julewire.log" }
  ]
)
```

Async output:

```ruby
config.destinations.use(
  :semantic_logger,
  formatter: Julewire::RecordFormatter.new,
  io: $stdout,
  async: true,
  max_queue_size: 10_000
)
```

Async moves blocking and drop behavior into Semantic Logger's queue. Keep
`max_queue_size` explicit and call `Julewire.flush` before shutdown when queued
records matter.

For multi-appender output, async lag options, and prebuilt appenders, see
[Advanced Configuration](advanced-configuration.md).
