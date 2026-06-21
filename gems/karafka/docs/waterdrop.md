# WaterDrop

Add the middleware before producing messages:

```ruby
Julewire::Karafka.install!(consumer: false, producer: producer)
```

The middleware injects the current Julewire propagation carrier into message
headers. The listener turns important WaterDrop monitor events into Julewire
point records.

Set `producer_event_names = :all` for every WaterDrop monitor event exposed by
the monitor, or pass an explicit event-name list. If the monitor cannot expose
its registered events, `:all` uses the important profile. WaterDrop event
severity is read from the event payload when present; otherwise errors are
error and normal producer events are info.

Set `carrier_max_bytes` to omit oversized propagation carriers from Kafka
headers. When omitted, the message is still produced normally; it just does not
carry upstream Julewire context.

Message keys, headers, and payload fields are raw unless an application installs
a processor policy before output.
