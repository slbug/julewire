# Propagation

When a job is serialized, the gem stores a Julewire carrier under
`julewire.carrier`. When the job performs, the carrier is restored before the
job execution scope starts.

That lets upstream context flow into the job without emitting propagation-only
data by default.

Fresh jobs capture the current context when serialized. A deserialized job keeps
its original carrier when serialized again, including when retried. An ambient
worker context or unrelated request cannot replace that origin. Jobs received
without a carrier remain without one. Instantiate a new job to capture another
context; child jobs capture their parent's live execution context.

`carrier_max_bytes` defaults to `65_536`. Oversized carriers are omitted from
serialized job payloads and ignored on restore. The job still runs normally; it
starts without upstream Julewire context.

Disabling propagation or changing `carrier_key` also prevents forwarding a saved
carrier under the previous setting. These cases never capture ambient context as
a replacement for the omitted carrier.

Generic job metadata such as class, id, queue, priority, execution count,
timestamps, and status is emitted in the record's `neutral` section as `job.*`
formatter-coordination fields. Full Active Job metadata, including framework-
specific status and exception fields, is emitted under `attributes.active_job`.

Status classification follows Active Job's normal `StandardError` path. Fatal
Ruby exceptions such as `SystemExit` or `NoMemoryError` are not converted into
job status metadata; they keep Ruby's process-level semantics.

Bulk enqueues use Active Job's serialization and execution contracts. Solid Queue
1.7 compatibility is checked separately with real batches, bulk-enqueued members,
and success, failure, and finish callbacks. Jobs retain their enqueue origin and
emit normal per-job records. Aggregate batch lifecycle and delivery remain the
queue backend's responsibility.

Solid Queue is not a runtime dependency or part of the default development bundle.
CI runs its separate integration suite on Ruby 3.4 and 4.0 when Active Job, core,
Rails support, or shared tooling changes. Run it locally from `gems/active_job`:

```sh
BUNDLE_GEMFILE=gemfiles/solid_queue.gemfile bundle install
bundle exec rake integration:solid_queue
```

The integration suite uses an in-memory SQLite database and Solid Queue's shipped
schema. It does not start a worker daemon or connect to an application database.
