# Health Schema

`Julewire.health` is an in-process operational snapshot. It is useful for
metrics, smoke checks, and debug pages. It is not a delivery receipt.

## Stable Fields

These fields are intended for integration dashboards and contract tests:

- `status`
- `closed`
- `generation`
- `counts`
- `last_failure`
- `last_callback_failure`
- `integrations.*.status`
- `integrations.*.counts`
- `integrations.*.last_failure`
- `process_integrations.*.status`
- `process_integrations.*.counts`
- `process_integrations.*.last_failure`
- `pipeline.configured`
- `pipeline.status`
- `pipeline.counts`
- `pipeline.last_callback_failure`
- `pipeline.last_failure`
- `destinations.*.status`
- `destinations.*.counts`
- `destinations.*.last_callback_failure`
- `destinations.*.last_failure`
- `destinations.*.last_loss`

Custom destination objects may expose their own nested health, but they own
those fields. Core direct destinations expose only core counters and loss
state.

`integrations.*` entries are runtime-local integration diagnostics. Use them
only when a failure can be honestly tied to a specific runtime.

`process_integrations.*` entries are process-owned integration diagnostics for
installs, framework subscribers, listeners, fork hooks, and other callbacks that
can fail before a record reaches a runtime. They expose only safe coordinates
such as integration name, component, action, phase, exception class, and
timestamp. A contained integration failure remains visible in `last_failure`,
but `status` can recover after the integration reports a later successful
operation.

Named runtimes have separate runtime-local `integrations`, pipeline, and
destination health, but they share `process_integrations`.

Top-level `counts` are process-runtime counters for the current runtime object.
`counts[:post_close_emits]` is scoped to the active runtime generation and resets
when a new pipeline is installed. `counts[:post_close_emits_total]` is the
runtime-lifetime total for the same rejected emits.
`counts[:invalid_record_severities]` is runtime-local; named runtimes do not
share that diagnostic count.
`pipeline.counts` and destination counters belong to the active pipeline and
reset on reconfigure. Top-level `generation` increments when configuration
installs a new pipeline.
`pipeline.counts[:processor_dropped]` counts intentional processor drops such
as sampling decisions; processor failures are counted separately under
`pipeline.counts[:processor_error]`.
Destination-local processors report the same `processor_dropped` and
`processor_error` counters under that destination's `counts`.

`status` fields describe current health for the active runtime generation.
Runtime, pipeline, and destination failure counters plus `last_failure` /
`last_loss` are historical. They remain visible after status recovers.
Destination loss or failure state recovers after a successful write or flush.
Integration state recovers after a successful integration operation. Pipeline
failure state recovers after a later emit completes without a pipeline failure.
Top-level `status` is `:ok`, `:degraded`, or `:closed`.
Pipeline `status` is `:unconfigured` before any destination is installed, then
`:ok` or `:degraded` for configured pipelines.

`destinations.*.last_loss` carries the last loss reason plus safe source,
event, severity, and timestamp metadata. It intentionally omits raw record data
and exception messages.

`destinations.*.last_failure` carries safe failure coordinates such as
exception class, phase, action, output class, and record coordinates when
available. It intentionally omits exception messages and raw output errors.

`Julewire.doctor` returns a scriptable summary built from `Julewire.health`.
It includes runtime, pipeline, destination, and integration status plus
warnings for unconfigured or degraded components.

## Diagnostic Fields

These are useful while debugging, but they are more implementation-shaped:

- output class names
- last callback failure phase
- invalid severity details
- runtime, pipeline, and destination failure details
- callback failure counts
- detailed loss taxonomies

Diagnostic fields may move or grow as internals change. Avoid long-lived alerts
that depend on exact nested delivery details unless the integration owns the
mapping.

Health intentionally omits raw exception messages. Do not expose private error
objects or raw sink messages from app health endpoints.
