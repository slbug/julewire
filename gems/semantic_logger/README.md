# Julewire Semantic Logger

`julewire-semantic_logger` is a Semantic Logger transport destination for
Julewire.

Julewire keeps its own record shape. Semantic Logger owns appender plumbing,
file/stdout output, optional async queues, flush, close, and reopen.

## Install

```ruby
gem "julewire-semantic_logger"
```

## Quickstart

```ruby
Julewire.configure do |config|
  config.destinations.use(
    :semantic_logger,
    formatter: Julewire::RecordFormatter.new,
    io: $stdout
  )
end
```

The adapter is synchronous by default. Enable async explicitly:

```ruby
Julewire.configure do |config|
  config.destinations.use(
    :semantic_logger,
    formatter: Julewire::RecordFormatter.new,
    io: $stdout,
    async: true,
    max_queue_size: 10_000
  )
end
```

## Docs

- [Configuration](docs/configuration.md)
- [Advanced Configuration](docs/advanced-configuration.md)
- [Transport](docs/transport.md)
- [Health](docs/health.md)
