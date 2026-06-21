# Julewire

Julewire is an execution-scoped structured logging toolkit for Ruby.

It is not a logger skin. Core owns record shape, context, propagation,
processors, summaries, health, and synchronous output contracts. Integrations
map Rails, Active Job, Karafka, GCP, Semantic Logger, and Ractor edges onto that
core without depending on each other.

## TL;DR

```ruby
Julewire.configure do |config|
  config.destinations.use(:default, output: $stdout)
end

Julewire.with_execution(type: :request, id: "req-1") do
  Julewire.context.add(tenant_id: "acme")
  Julewire.summary.increment(:db_queries)
  Julewire.measure(:render) do
    Julewire.emit("handled", event: "orders.show", order_id: 123)
  end
end
```

Records are newline JSON by default. Framework gems add request/job/message
lifecycles, structured events, propagation carriers, and provider formatting.

## Gems

| Gem | Path | Job |
| --- | --- | --- |
| `julewire-core` | [gems/core](gems/core) | Runtime, records, context, processors, destinations, contracts. |
| `julewire-rack` | [gems/rack](gems/rack) | Shared Rack-family request support. |
| `julewire-rails` | [gems/rails](gems/rails) | Rails logger, request summaries, Rails events, Rails errors. |
| `julewire-rails_support` | [gems/rails_support](gems/rails_support) | Shared Rails-family support. |
| `julewire-active_job` | [gems/active_job](gems/active_job) | Job summaries, job events, and propagation through job data. |
| `julewire-karafka` | [gems/karafka](gems/karafka) | Karafka/WaterDrop events, message context, and Kafka carriers. |
| `julewire-gcp` | [gems/gcp](gems/gcp) | Google Cloud Logging JSON shape, trace fields, Error Reporting shape. |
| `julewire-redaction` | [gems/redaction](gems/redaction) | Bounded whole-record redaction processor. |
| `julewire-semantic_logger` | [gems/semantic_logger](gems/semantic_logger) | Semantic Logger transport bridge. |
| `julewire-ractor` | [gems/ractor](gems/ractor) | Experimental Ruby 4.0 Ractor bridge. |

## Rails API Stack

The normal Rails API setup is:

```ruby
gem "julewire-rails"
gem "julewire-active_job"
gem "julewire-gcp"
gem "julewire-redaction"
gem "julewire-semantic_logger"
```

Then wire one destination and the filtering policy:

```ruby
Julewire.configure do |config|
  config.processors.prepend(
    :rails_parameter_filter,
    Rails.application.config.filter_parameters
  )

  config.destinations.use(
    :semantic_logger,
    formatter: Julewire::GCP::Formatter.new(project_id: "my-project"),
    io: $stdout
  )
end
```

Rails hash event payloads are filtered by Rails before subscribers see them.
Whole-record filtering for logger payloads and optional captured fields is a
Julewire processor decision.

## Developer Tools

`julewire tail` renders newline JSON logs as compact console text. Provider gems
can register their own decoders, so GCP-shaped Kubernetes logs can be tailed
without core knowing the GCP wire shape:

```sh
kubectl logs -f deploy/my-app | julewire tail --format gcp --raw-invalid -
```

`julewire transcode` reads one registered format and writes another:

```sh
kubectl logs deploy/my-app | julewire transcode --from gcp --to core --raw-invalid -
```

See [gems/core/docs/tail.md](gems/core/docs/tail.md) for the full CLI surface.

## Shape

Julewire records are split into field bags:

- `context`: queryable facts copied onto records and summaries; propagates.
- `carry`: hidden forwarding metadata; propagates.
- `attributes`: emitted integration/application namespaces.
- `neutral`: provider-neutral formatter coordination facts.
- `summary`: final counters, timings, and completion facts.
- `labels`: operator-safe routing/grouping metadata.
- `metrics`: numeric measurements such as duration.

The core serializer bounds depth, arrays, hashes, strings, cycles, invalid
encoding, non-finite numerics, and exception shapes. It is a safety layer, not a
privacy layer; redaction is explicit processor policy.

## Repo

This is a monorepo with independently-packaged gems under `gems/`. CI is
path-filtered by gem; Codecov uses per-gem carryforward flags so partial runs do
not pretend untouched gems went dark.

## Development

Each gem owns its test task:

```sh
cd gems/core
COVERAGE=true bundle exec rake
```

The root `Rakefile` can orchestrate all gem tasks from a Ruby environment with
the gem bundles installed. Rails Appraisal suites live in `gems/rails`; the
Ractor gem runs on Ruby 4.0 only.

## License

MIT. Each packaged gem includes its own `LICENSE.txt`; the repository-level
license is [LICENSE.txt](LICENSE.txt).
