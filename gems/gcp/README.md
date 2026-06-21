# Julewire GCP

Google Cloud Logging structured JSON formatter and direct-output destination
for Julewire records.

It does not own queues, batching, retries, or network transport.

## Quickstart

```ruby
gem "julewire-gcp"
```

```ruby
Julewire.configure do |config|
  config.destinations.use(
    :gcp,
    formatter: Julewire::GCP::Formatter.new(project_id: "my-project"),
    output: $stdout
  )
end
```

Default shape:

- Cloud Logging special fields: `severity`, `message`, `time`, `httpRequest`,
  labels, operation, source location, trace, span, and trace sampled
- remaining Julewire fields in JSON payload
- records with neutral HTTP attributes mapped to `httpRequest`
- stack traces promoted for Error Reporting when core-shaped errors include
  backtrace lines

## Docs

- [Configuration](docs/configuration.md)
- [Advanced Configuration](docs/advanced-configuration.md)
- [Shape](docs/shape.md)
- [Trace](docs/trace.md)
- [Error Reporting](docs/error-reporting.md)
- [Development](docs/development.md)
