# Advanced Configuration

These options are stable knobs for unusual job serialization or event naming
needs.

| Option | Default | Purpose |
| --- | --- | --- |
| `carrier_key` | `Julewire::Core::Propagation::Carrier::DEFAULT_KEY` | Carrier key inside propagation envelopes. |
| `serialized_carrier_key` | `"julewire.carrier"` | Key used in serialized Active Job data. |
| `summary_event` | `"job.completed"` | Event name for job summaries. |
| `summary_severity` | `:info` | Severity for successful job summaries. |
| `event_prefixes` | `["active_job."]` | Structured event prefixes to emit. |
