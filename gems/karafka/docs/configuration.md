# Configuration

## Default Path

| Option | Default | Purpose |
| --- | --- | --- |
| `enabled` | `true` | Install the integration. |
| `consumer_events` | `true` | Subscribe Karafka monitor events. |
| `producer_events` | `true` | Subscribe WaterDrop monitor events. |
| `propagation` | `true` | Inject and restore Julewire carriers. |
| `source` | `"karafka"` | Source value on Karafka and WaterDrop records. |

## Common Knobs

| Option | Default | Purpose |
| --- | --- | --- |
| `carrier_max_bytes` | `65_536` | Omit oversized carriers from Kafka headers. |
| `carrier_filter` | `nil` | Optional inbound header filter before restoring a message carrier. |
| `consumer_event_names` | `:important` | Consumer monitor event profile or explicit event list. |
| `producer_event_names` | `:important` | Producer monitor event profile or explicit event list. |

`consumer_event_names` and `producer_event_names` accept:

- `:important`
- `:all`
- an explicit event-name list

`:all` uses the monitor's registered event list when available. If the monitor
cannot expose that list, Julewire uses the important profile.

Example:

```ruby
Julewire::Karafka.configure do |config|
  config.consumer_event_names = :all
  config.carrier_max_bytes = 16_384
end
```

`carrier_filter` receives `(headers, message:)` and must return the headers to
trust. Leave it unset for internal topics. Return `{}` for untrusted messages:

```ruby
Julewire::Karafka.configure do |config|
  config.carrier_filter = ->(headers, message:) {
    internal_topic?(message[:topic]) ? headers : {}
  }
end
```
