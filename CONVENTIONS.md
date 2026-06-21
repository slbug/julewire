# Julewire Conventions

This file is the house style for integration gems in this monorepo. It is not a
new contract tier; the contract tiers still live in each gem's docs.

## Boundaries

Core owns record shape, propagation, processors, destinations, health, tailing,
and framework-neutral integration helpers. Core must not reference Rails,
Active Support, Karafka, WaterDrop, GCP, or Semantic Logger constants.
Integration gems must use documented `Core::...` constants directly; dynamic
constant lookup must not bypass the SPI boundary.

The root boundary linter checks static constant references. Method calls gained
through included modules are reviewed by convention and tests, not inferred by
the linter.

Framework catalogs and framework lifecycle wiring live in their integration
gems. Shared Rails-family mechanics live in `julewire-rails_support`, not core.
Ractor-only wiring uses the bridge SPI documented by `julewire-ractor`.

Sibling gems should not depend on each other unless there is a deliberately
named support gem for that family, such as `julewire-rails_support`.

## Configuration

Use the core settings/configurable helpers for process-wide integration config:

- app-framework integrations such as Active Job, Karafka, and Redaction expose
  `config`, `configure`, and `reset!`;
- provider/transport objects such as GCP formatters and Semantic Logger
  destinations prefer constructor options because they are destination-local;
- Rails uses Railtie application config because Rails apps expect
  `config.julewire_rails`.

When a setting changes install behavior, installers must be idempotent and must
unsubscribe/reset where the framework exposes a clean unsubscribe API.

## Health

Integration gems use `IntegrationHealth = Core::Integration::Health.scoped(:name)`
and record failures with `component`, `action`, and safe metadata. Do not
include raw payloads or exception messages in integration-health records.

Process-integration health is global. Use runtime-local integration health only
when the failure can be tied honestly to a specific runtime. Named runtimes
isolate runtime/pipeline health; process-integration state represents the
process-level adapter edge.

## Events

Event subscriber classes use `Core::Integration::EventSubscriber` and
`Core::Integration::SubscriberInstall` when the framework has a subscribe API.
Framework event catalogs stay in the framework gem and should have a small
canary test against the current framework catalog or load path.

Event names emitted into Julewire records should keep the framework's native
name in `event` when possible. Framework-specific details go under
`attributes.<framework>`, while provider-neutral formatter facts go under
`neutral`.

## Records

Use field bags consistently:

- `context`: queryable facts copied onto records and summaries;
- `carry`: propagation-only metadata that default formatters hide;
- `attributes`: application and framework namespaces;
- `neutral`: provider-neutral formatter coordination facts;
- `summary`: final counters and completion facts;
- `labels`: operator routing/grouping;
- `metrics`: numeric measurements.

Whole-record processors should preserve structural fields and use core record
shape helpers instead of hand-rolled section lists.
