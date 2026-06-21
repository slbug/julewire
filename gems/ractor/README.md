# Julewire Ractor

`julewire-ractor` is the experimental Ractor bridge for Julewire.

It requires Ruby 4.0 or newer. Code inside `Julewire.ractor` can emit through
the parent runtime while the parent keeps configuration, processors,
destinations, outputs, and labels authoritative.

## Install

```ruby
gem "julewire-ractor"
```

## Quickstart

```ruby
Julewire.configure do |config|
  config.destinations.use(:default, output: $stdout)
end

Julewire.enable_experimental_ractor!

ractor = Julewire.ractor do
  Julewire.emit(message: "from ractor")
  Julewire.flush
end

ractor.value
```

This is best-effort logging infrastructure, not durable transport.

Child-side send failures are visible from inside the child:

```ruby
Julewire.ractor do
  Julewire.emit(message: "from ractor")
  Julewire::Ractor.child_stats
end.value
```

For CPU-heavy formatting/encoding experiments, the gem can make the normal
`:default` destination kind ractor-backed. The parent pipeline stays synchronous
up to the immutable record boundary, then the worker ractor owns formatter,
encoder, and output:

```ruby
Julewire::Ractor.enable_default_destination_workers!

Julewire.configure do |config|
  config.destinations.use(:default, output: MyRactorCopyableOutput.new)
end
```

Use the explicit `:ractor` kind when a second ractor-backed destination should
sit beside another destination. Formatter, encoder, and output must be
ractor-copyable or shareable under Ruby's Ractor rules.

## Docs

- [Bridge](docs/bridge.md)
