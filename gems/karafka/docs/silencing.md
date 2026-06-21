# Silencing

Karafka and WaterDrop logger listeners are application-installed monitor
listeners, not global framework subscribers. The clean replacement is to remove
the native logger-listener subscription where the application installs it:

```ruby
Karafka.monitor.subscribe(Karafka::Instrumentation::LoggerListener.new)
```

Replace that with:

```ruby
Julewire::Karafka.install!(monitor: Karafka.monitor)
```

If application boot code needs to keep the native listener for some
environments, keep a reference and unsubscribe that same listener before
installing Julewire:

```ruby
native_logger = Karafka::Instrumentation::LoggerListener.new
Karafka.monitor.subscribe(native_logger)

Karafka.monitor.unsubscribe(native_logger)
Julewire::Karafka.install!(monitor: Karafka.monitor)
```

For WaterDrop, do the same with `WaterDrop::Instrumentation::LoggerListener`
on the producer monitor and use
`Julewire::Karafka.install!(consumer: false, producer: producer)`.

This gem does not parse text logs or filter duplicate logger messages. Explicit
logger calls made by application code remain normal Julewire `event: "log"`
records.
