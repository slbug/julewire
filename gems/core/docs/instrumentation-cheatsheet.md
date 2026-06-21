# Instrumentation Cheatsheet

Use the smallest entrypoint that matches the work:

| Need | API |
| --- | --- |
| Add ambient fields | `Julewire.context.add(...)`, `Julewire.attributes.add(...)`, `Julewire.carry.add(...)` |
| Emit a point record | `Julewire.info("message", attributes: {...})` |
| Wrap work with a summary | `Julewire.with_execution(type: :job, id: id) { ... }` |
| Measure block-shaped work | `Julewire.measure(:db) { query }` |
| Measure split start/finish work | `handle = Julewire.measure_start(:db); handle.finish` |
| Install a destination | `config.destinations.use(:default, output: $stdout)` |
| Tail local records | `julewire tail log/julewire.jsonl --format=auto --follow` |

Field placement:

| Field bag | Use for |
| --- | --- |
| `context` | Request/job/message identity useful on every record in scope. |
| `carry` | Propagation data that may cross process boundaries. |
| `neutral` | Provider-neutral semantic fields such as HTTP, job, code, or messaging keys. |
| `attributes` | Framework/app-specific structured data. |
| `payload` | User event payload for point records and summary counters. |
| `metrics` | Numeric summary measurements. |
| `labels` | Operator routing labels. |

`logger` names the entrypoint that produced the record, such as
`"framework.error"` or `"job.event"`. `source` names the integration or
runtime producer, such as `"web"`, `"job"`, or `"julewire"`.
