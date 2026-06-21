# Julewire Karafka

Karafka and WaterDrop integration for Julewire.

It uses structured integration points only: Karafka monitor events, WaterDrop
middleware, WaterDrop monitor events, and explicit per-message context
restoration.

## Quickstart

Consumer events:

```ruby
class KarafkaApp < Karafka::App
  setup do |config|
    Julewire::Karafka.install!(monitor: config.monitor)
  end
end
```

Message processing:

```ruby
def consume
  messages.each do |message|
    Julewire::Karafka.with_message(message) do
      process(message)
      mark_as_consumed(message)
    end
  end
end
```

Producer headers and WaterDrop events:

```ruby
Julewire::Karafka.install!(consumer: false, producer: producer)
```

Default behavior:

- important consumer and producer monitor events become point records
- message headers carry Julewire propagation carriers
- `with_message` restores message context and adds message attributes
- Karafka fork hooks call `Julewire.after_fork!`
- text logger listeners are not parsed or deduplicated

Inbound Kafka carriers are trusted by default for internal service traffic. Set
`carrier_filter` when consuming topics that external producers can write to.

## Docs

- [Configuration](docs/configuration.md)
- [Advanced Configuration](docs/advanced-configuration.md)
- [Consumer Events](docs/consumer-events.md)
- [Message Context](docs/message-context.md)
- [WaterDrop](docs/waterdrop.md)
- [Silencing](docs/silencing.md)
