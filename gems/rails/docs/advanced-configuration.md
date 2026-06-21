# Advanced Configuration

These options are rarely needed for normal Rails apps.

| Option | Default | Purpose |
| --- | --- | --- |
| `logger_name` | `"Rails"` | Logger name on Rails logger records. |
| `lifecycle_hooks` | `true` | Install at-exit and Rails fork hooks. |
| `log_rescued_responses` | `:auto` | Control Rails raw rescued-response exception text. |
| `reported_exception_logs` | `:auto` | Control raw `ActionDispatch::DebugExceptions` report text. |
| `require_output` | `:warn` | Warn/raise when Julewire owns `Rails.logger` but has no output. |
| `shutdown_timeout` | `1` | Timeout used by lifecycle flush/close hooks. |
| `summary_event` | `"request.completed"` | Event name for request summaries. |

`log_rescued_responses` and `reported_exception_logs` should usually stay on
`:auto`. That lets Julewire suppress duplicate framework text when it owns the
Rails logger while keeping Rails' own behavior when it does not.
