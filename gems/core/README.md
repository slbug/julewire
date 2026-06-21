# Julewire Core

`julewire-core` is the synchronous structured logging runtime behind Julewire.

It builds provider-neutral records, execution context, propagated carry,
non-propagated attributes, final summaries, processor chains, and synchronous
direct outputs. It does not know about app frameworks, privacy policy, provider
schemas, async queues, or delivery.

## Install

```ruby
gem "julewire-core"
```

## Quickstart

```ruby
Julewire.configure do |config|
  config.destinations.use(:default, output: $stdout)
end

Julewire.with_execution(type: :job, id: "job-1") do
  Julewire.context.add(tenant_id: "tenant-1")
  Julewire.summary.increment(:records_seen)

  Julewire.measure(:process_record) do
    Julewire.emit("processed record", id: 123)
  end
end
```

By default, direct output is newline-delimited JSON.

## Field Bags

| Bag | Use it for | Propagates? | Default JSON? |
| --- | --- | --- | --- |
| `context` | queryable facts copied onto records in the current scope | yes | yes |
| `carry` | hidden forwarding metadata for integrations and formatters | yes | no |
| `neutral` | provider-neutral formatter-coordination facts | no | no |
| `attributes` | integration and application namespaces | no | yes |
| `summary` | final-only counters, timings, and completion facts | no | summary only |
| `labels` | operator-safe routing/grouping metadata | no | yes |
| `metrics` | numeric measurements such as duration | no | yes |

## Docs

- [Quickstart](docs/quickstart.md)
- [Configuration](docs/configuration.md)
- [Advanced Configuration](docs/advanced-configuration.md)
- [Context and Propagation](docs/context-and-propagation.md)
- [Instrumentation Cheatsheet](docs/instrumentation-cheatsheet.md)
- [Attribute Keys](docs/attribute-keys.md)
- [Records and Data Policy](docs/records-and-data-policy.md)
- [Outputs and Lifecycle](docs/outputs-and-lifecycle.md)
- [Developer Tail](docs/tail.md)
- [Health Schema](docs/health-schema.md)
- [Security and Wire Keys](docs/security-and-wire.md)
- [Extension Contracts](docs/contracts.md)
- [Extensions and API](docs/extensions-and-api.md)
- [Record Sources](docs/record-sources.md)
- [Internals](docs/internals.md)
- [Development](docs/development.md)

## Runtime Promise

Julewire is best-effort logging infrastructure. `StandardError` failures inside
Julewire's own normalization, processing, formatting, encoding, and output path
are contained so application code keeps running.

Core stays synchronous. Custom destinations own async queues, files, fanout,
batching, retries, and delivery health.
