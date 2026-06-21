# Julewire Active Job

Active Job integration for Julewire.

It records job execution summaries, Active Job structured events, and Julewire
propagation carriers in serialized job data.

## Quickstart

```ruby
gem "julewire-active_job"
```

In Rails, the Railtie installs the integration. Defaults are on:

```ruby
config.julewire_active_job.execution = true
config.julewire_active_job.structured_events = true
config.julewire_active_job.propagation = true
```

Outside Rails, install it after Active Job is loaded:

```ruby
Julewire::ActiveJob.install!(base: ActiveJob::Base)
```

Default behavior:

- job execution scopes emit `job.completed` summaries
- Active Job structured events become point records
- carriers restore upstream Julewire context before `perform`
- Active Job default text subscriber output is detached

Generic job metadata also appears in the record's `neutral` section as `job.*`
formatter-coordination fields. Full Active Job detail lives under
`attributes.active_job`. Propagated Julewire context stays separate and small.

## Docs

- [Configuration](docs/configuration.md)
- [Advanced Configuration](docs/advanced-configuration.md)
- [Propagation](docs/propagation.md)
- [Continuations](docs/continuations.md)
- [Boundaries](docs/boundaries.md)
