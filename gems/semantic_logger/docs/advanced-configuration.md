# Advanced Configuration

## Prebuilt Transport

Pass `transport:` when construction needs to happen outside the destination:

```ruby
transport = Julewire::SemanticLogger::Transport.new(io: $stdout)

config.destinations.use(
  :semantic_logger,
  formatter: Julewire::RecordFormatter.new,
  transport: transport
)
```

## Prebuilt Appenders

Pass an existing Semantic Logger appender with `appender:`:

```ruby
config.destinations.use(
  :semantic_logger,
  formatter: Julewire::RecordFormatter.new,
  appender: my_appender
)
```

## Async Lag Options

These options are passed to `SemanticLogger::Appender::Async` when
`async: true`:

| Option | Default |
| --- | --- |
| `lag_check_interval:` | `1_000` |
| `lag_threshold_s:` | `30` |

## Async Queue Options

Transport-level async options are passed to the Semantic Logger async proxy
when the installed Semantic Logger version supports them. Semantic Logger 4.18
supports queue size and lag options. Semantic Logger 5 also supports
`non_blocking:`, `dropped_message_report_seconds:`, and `async_max_retries:`.
Setting a non-default unsupported async option raises a configuration error.

`batch: true` uses `SemanticLogger::Appender::AsyncBatch` on Semantic Logger 4
and `SemanticLogger::Appender::Async` batch mode on Semantic Logger 5. Batch
mode implies async output.

## Appender Defaults

Unknown transport options are merged into each appender spec. This is useful for
Semantic Logger appender-specific options:

```ruby
config.destinations.use(
  :semantic_logger,
  formatter: Julewire::RecordFormatter.new,
  appenders: [
    { io: $stdout },
    { file_name: "log/julewire.log" }
  ],
  level: :debug
)
```
