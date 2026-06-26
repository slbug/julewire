# Propagation

When a job is serialized, the gem stores a Julewire carrier under
`julewire.carrier`. When the job performs, the carrier is restored before the
job execution scope starts.

That lets upstream context flow into the job without emitting propagation-only
data by default.

`carrier_max_bytes` defaults to `65_536`. Oversized carriers are omitted from
serialized job payloads and ignored on restore. The job still runs normally; it
starts without upstream Julewire context.

Generic job metadata such as class, id, queue, priority, execution count,
timestamps, and status is emitted in the record's `neutral` section as `job.*`
formatter-coordination fields. Full Active Job metadata, including framework-
specific status and exception fields, is emitted under `attributes.active_job`.
