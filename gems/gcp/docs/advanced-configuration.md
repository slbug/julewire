# Advanced Configuration

| Option | Default | Purpose |
| --- | --- | --- |
| `trace_headers_paths` | `carry.http.request_headers`, then secondary paths | Request trace-header paths. |
| `trace_id_path` | `nil` | Explicit path to trace id. |
| `span_id_path` | `nil` | Explicit path to span id. |
| `trace_sampled_path` | `nil` | Explicit path to sampling flag. |
| `label_formatter` | `nil` | Custom label formatter. |
| `label_options` | `{}` | Options passed to the default label formatter. |

Use explicit trace paths when trace facts are already normalized into record
fields and no header parsing is needed:

```ruby
Julewire::GCP::Formatter.new(
  project_id: "my-project",
  trace_id_path: %i[attributes trace_id],
  span_id_path: %i[attributes span_id],
  trace_sampled_path: %i[attributes trace_sampled]
)
```

Use `label_formatter` only when the default label limits or key formatting are
not enough.
