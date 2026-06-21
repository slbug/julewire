# Consumer Events

`Julewire::Karafka.install!` subscribes to an `:important` event profile by default.
Set `consumer_event_names = :all` to subscribe to Karafka's registered monitor
events, or pass an explicit event list for application policy. If the monitor
cannot expose its registered events, `:all` uses the important profile.

`install!` also subscribes lightweight handlers for
`swarm.node.after_fork` and `swarm.manager.after_fork`. Those handlers call
`Julewire.after_fork!` so inherited mutexes, counters, async transports, and
process-local context are reset in Karafka forked processes.

Monitor events use the severity exposed by the event payload when Karafka
provides one. Otherwise the listener follows Karafka's logger-listener severity
conventions: normal lifecycle/consumer events are info, polling and swarm
control events are debug, selected fatal framework errors are fatal, and other
errors are error.

Consumer batch lifecycle records such as `consumer.consumed` include batch
metadata when Karafka exposes it: consumer class/id, group ids, topic,
partition, message count, offset range, and lag metrics.

Generic Kafka metadata also appears in the record's `neutral` section as
`messaging.*` formatter-coordination fields. Full Karafka or WaterDrop event
metadata remains under `attributes.karafka` or `attributes.waterdrop`.

These records describe the batch lifecycle. They are not the propagation
boundary. Generic array values in monitor payloads are summarized as
`{ count: n }` to keep records bounded.

Karafka `error.occurred` records use Julewire's normal top-level `error` shape,
including the core backtrace policy. Error event attributes still carry Karafka
metadata such as event type and consumer/batch details.
