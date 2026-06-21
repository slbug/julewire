# Developer Tail

`Julewire::Tail` is a bounded in-memory destination for local inspection. It is
not delivery, buffering, or audit storage.

```ruby
tail = Julewire::Tail.attach!(capacity: 200)

Julewire.info("booted", service: "api")

puts tail.render(limit: 20)
```

`Julewire.tail` attaches a tail destination to the default runtime:

```ruby
tail = Julewire.tail(capacity: 100)
```

The tail stores public formatter output after Julewire's normal processors have
run. It omits hidden carry data and execution-lineage internals, and it applies
core serializer bounds before records enter the ring buffer. `tail.records`
returns frozen snapshots; `tail.render` returns one-line text; `tail.write(io)`
writes that text to an IO.

Use `Julewire::ConsoleFormatter` with `Julewire::TextEncoder` for normal
stdout text destinations. Tail uses the same text encoder for its rendered
view.

## CLI Tail

`julewire tail` reads JSON logs from a file or stdin and renders compact text:

```sh
julewire tail --format core log/development.jsonl
```

Provider gems can register their own file decoders, so mixed platform stdout can
be tailed without teaching core about provider log envelopes:

```sh
platform logs -f service/my-app | julewire tail --format provider_json --raw-invalid -
```

Core decoders own Julewire's core JSON shape; provider gems own provider wire
shapes.

`julewire --version` prints the core CLI version.

Parsing is strict by default. Use `--skip-invalid` to ignore non-JSON lines or
`--raw-invalid` to print boot noise and platform lines unchanged while decoded
Julewire records are rendered normally.

`julewire transcode` uses the same provider-owned decoders, then writes another
registered output format. Core ships `core` JSON and `console` text; provider
gems can register their own output formats:

```sh
platform logs service/my-app | julewire transcode --from provider_json --to core --raw-invalid -
```

`Julewire::TextEncoder.new(theme: :punk)` is a high-contrast local console
style. `Julewire.punk!` configures a named runtime with that formatter/encoder
pair.

`julewire doctor --punk` renders the doctor report as loud terminal text. Plain
`julewire doctor` stays JSON for scripts.

`Julewire.dev!` configures the same console and attaches a tail in one core-only
call:

```ruby
tail = Julewire.dev!(tail: { capacity: 500 })
```

Use a custom formatter when the local view should differ from default output:

```ruby
tail = Julewire::Tail.attach!(
  formatter: ->(record) { { severity: record.fetch(:severity), message: record.fetch(:message) } }
)
```

The tail is a normal custom destination. `Julewire.health` reports its size,
capacity, capture count, and formatter failures under the tail destination name.

`Julewire::TailSampling` is separate from the developer tail. It wraps another
destination and buffers records until an execution summary decides whether to
keep the execution. Errors and slow executions are kept; the rest are sampled
with Julewire's deterministic sampling hash. Pass `decider:` for a custom callable
policy; it receives the summary record and `key:`.
