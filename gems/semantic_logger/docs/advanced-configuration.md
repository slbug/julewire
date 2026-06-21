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
