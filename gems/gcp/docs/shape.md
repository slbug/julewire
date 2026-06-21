# Shape

The formatter maps Julewire records to the special JSON fields recognized by
Cloud Logging agents:

- `severity`
- `message`
- `time`
- `httpRequest`
- `logging.googleapis.com/labels`
- `logging.googleapis.com/operation`
- `logging.googleapis.com/sourceLocation`
- `logging.googleapis.com/trace`
- `logging.googleapis.com/spanId`
- `logging.googleapis.com/trace_sampled`

The remaining non-empty Julewire data stays queryable in the JSON payload:

- `payload`
- `attributes`
- `serviceContext` when configured
- `julewire.kind`
- `julewire.event`
- `julewire.logger`
- `julewire.source`
- `julewire.execution`
- `julewire.context`
- `julewire.error`
- `julewire.metrics`

Records are mapped into `httpRequest` when they include provider-neutral HTTP
fields in the record's `neutral` section:

- `http.request.method`
- `url.full`
- `url.path`
- `http.response.status_code`
- `user_agent.original`
- `client.address`
- `http.response.body.size`

`httpRequest.latency` comes from `metrics.duration_ms` when present.

The formatter reads these core neutral HTTP attributes to build `httpRequest`.
Integration-specific attribute namespaces stay queryable.

Records are mapped into `logging.googleapis.com/sourceLocation` when they carry
neutral `code.file.path`, `code.line.number`, or `code.function.name` attributes
in the record's `neutral` section. Explicit `payload.gcp.source_location` wins.

When a record has HTTP method, URL or path, and status but no explicit message,
the formatter emits a concise HTTP-derived message such as
`GET /orders -> 200 in 24.1ms`.

Request summaries are marked as `logging.googleapis.com/operation.last = true`.
The formatter does not infer `operation.first`; mark that specific record
explicitly when it matters:

```ruby
Julewire.with_execution(type: :job, id: "job-1") do
  Julewire.emit(
    event: "job.started",
    source: "worker",
    payload: Julewire::GCP.operation(first: true)
  )
end
```

GCP output keeps public execution fields under `julewire.execution`.
Lineage internals are omitted. Execution fields promoted to GCP-native fields,
such as `logging.googleapis.com/operation.id` or configured trace paths, are
not duplicated there.

For records without an execution, provide an operation id:

```ruby
Julewire.emit(
  event: "script.started",
  source: "script",
  payload: Julewire::GCP.operation(
    id: "nightly-import-20260531",
    producer: "script",
    first: true
  )
)
```

The formatter consumes `payload.gcp.operation` and
`payload.gcp.source_location` as control metadata and removes those control keys
from emitted application payload.

Add source-location metadata when the application has a meaningful code location
to attach to a record:

```ruby
Julewire.emit(
  event: "import.started",
  payload: Julewire::GCP.source_location(
    file: "app/jobs/import_job.rb",
    line: 42,
    function: "ImportJob#perform"
  )
)
```
