# Message Context

Kafka batches can contain messages from different upstream requests. Do not use
batch events as the propagation boundary. Wrap each message while processing it:

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

`with_message` restores the Julewire carrier from that message's headers and
adds message attributes for records emitted inside the block. It does not emit a
success log or summary by default.

Generic Kafka metadata appears in the record's `neutral` section as
`messaging.*` formatter-coordination fields. Full Karafka message metadata
remains under `attributes.karafka`.

By default, inbound Kafka carriers are trusted because most Kafka traffic is
internal service-to-service traffic. Set `carrier_filter` when consuming topics
that external producers can write to.

Code inside the block can enqueue jobs, produce messages, or emit records. Core
propagation carries upstream context and execution metadata, not the Karafka
message attributes.

Use `with_message_execution` only when consumer code chooses an explicit message
unit of work and wants a summary for that block:

```ruby
def consume
  messages.each do |message|
    Julewire::Karafka.with_message_execution(message) do
      process(message)
    end
  end
end
```

This is intentionally opt-in. Batch-level summaries can conflate unrelated
upstream request contexts, and per-message summaries are useful only when the
consumer treats each message as an observable unit of work.

`with_message_execution` accepts `type:`, `id:`, `emit_summary:`,
`summary_event:`, `summary_severity:`, and `summary_source:`. Other keyword
arguments become execution fields. By default, type is `:karafka_message`, id is
`"topic:partition:offset"` when those message fields are present, and the
summary event is `"message.completed"`.
