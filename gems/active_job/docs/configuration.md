# Configuration

Rails apps configure this gem through `config.julewire_active_job`. Non-Rails
apps pass a `Configuration` instance to `install!`.

## Default Path

| Option | Default | Purpose |
| --- | --- | --- |
| `enabled` | `true` | Install the integration. |
| `execution` | `true` | Wrap job perform calls in Julewire executions. |
| `structured_events` | `true` | Emit Active Job structured events. |
| `propagation` | `true` | Store and restore Julewire carriers in job data. |
| `source` | `"active_job"` | Source value on Active Job records. |

## Common Knobs

| Option | Default | Purpose |
| --- | --- | --- |
| `carrier_max_bytes` | `nil` | Omit oversized carriers from serialized jobs. |
| `silence_log_subscriber` | `true` | Detach Active Job default text subscriber output. |

Example:

```ruby
config.julewire_active_job.carrier_max_bytes = 16_384
```
