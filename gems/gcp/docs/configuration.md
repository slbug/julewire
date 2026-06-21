# Configuration

## Default Path

| Option | Default | Purpose |
| --- | --- | --- |
| `project_id` | `nil` | Expand bare trace IDs to Cloud Trace resource names. |
| `service_context` | `nil` | Add Error Reporting service/version context. |
| `max_record_bytes` | `256 KiB` | Destination record-size cap from `Julewire::GCP::Destination`. |

## Common Knobs

| Option | Default | Purpose |
| --- | --- | --- |
| `operation_producer` | `nil` | Override `logging.googleapis.com/operation.producer`. |
| `max_labels` | `64` | Maximum Cloud Logging labels emitted. |
| `max_label_key_bytes` | `512` | Maximum label key byte size. |
| `max_label_value_bytes` | `65_536` | Maximum label value byte size. |

Oversized label values are truncated. Oversized label keys are dropped because
Cloud Logging rejects invalid label keys.

Example:

```ruby
Julewire::GCP::Formatter.new(
  project_id: "my-project",
  service_context: { service: "web", version: "2026-05-31" }
)
```

`Julewire::GCP::Destination` uses `Julewire::GCP::RECOMMENDED_MAX_RECORD_BYTES`
as a conservative `max_record_bytes` default.
