# Health

The destination health surface is transport-shaped.

```ruby
Julewire.health
```

Destination health includes:

- destination `status`
- destination write/failure counts
- transport write/failure counts
- async queue state
- file appender metadata
- child appender shape for multi-appender output
- lifecycle warnings

Lifecycle warnings currently include:

- `:async_queue_blocks_when_full`
- `:async_queue_unbounded`
- `:sync_multi_appender_blocks_emitters`

The adapter does not recreate transport-level drop taxonomy. Semantic Logger
owns async worker behavior; Julewire reports the transport state it can observe.

## Metric Mapping

One practical mapping is:

| Health path | Metric name |
| --- | --- |
| `counts.*` | `julewire_runtime_total{event}` |
| `pipeline.counts.*` | `julewire_pipeline_total{event}` |
| `destinations.*.counts.*` | `julewire_destination_total{destination,event}` |
| `destinations.*.last_loss.reason` | `julewire_destination_last_loss{destination,reason}` |
| `destinations.*.transport.counts.*` | `julewire_semantic_logger_transport_total{destination,event}` |
| `destinations.*.transport.appender.queue_size` | `julewire_semantic_logger_queue_size{destination}` |
| `destinations.*.transport.appender.max_queue_size` | `julewire_semantic_logger_queue_capacity{destination}` |
| `destinations.*.transport.warnings.*` | `julewire_semantic_logger_warning{destination,reason}` |

Treat core health paths as inputs, not as a global metrics schema.
