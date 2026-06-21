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
