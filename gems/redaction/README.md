# Julewire Redaction

`julewire-redaction` is a structured redaction processor for Julewire records.

It redacts data inside the core processor pipeline before records are frozen,
formatted, encoded, and written.

## Install

```ruby
gem "julewire-redaction"
```

## Quickstart

```ruby
Julewire::Redaction.configure do |config|
  config.filters = Julewire::Redaction::DEFAULT_FILTERS + %i[session_id]
  config.mask = "[FILTERED]"
end

Julewire.configure do |config|
  config.processors.prepend :redaction, on_error: :fail_closed
end
```

Configure redaction before `Julewire.configure`, or pass explicit options to
the processor registration.

`DEFAULT_FILTERS` combines `SECRET_FILTERS` and `PII_FILTERS`; use the narrower
profile when fields such as email are acceptable in your logs.

Prepend the processor when redaction should run before enrichment and output
formatting.

## Docs

- [Configuration](docs/configuration.md)
- [Advanced Configuration](docs/advanced-configuration.md)
- [Filter Rules](docs/filter-rules.md)
- [String Values](docs/string-values.md)
- [Failure Semantics](docs/failure-semantics.md)
