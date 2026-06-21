# Advanced Configuration

| Option | Default | Purpose |
| --- | --- | --- |
| `carrier_key` | `Julewire::Core::Propagation::Carrier::DEFAULT_KEY` | Carrier key inside propagation envelopes. |

Change `carrier_key` only when an existing Kafka header contract requires a
different envelope key.
