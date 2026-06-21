# Advanced Configuration

## Traversal Limits

The processor bounds its walk before the final core serializer runs.
When a redaction walk hits these limits, it may truncate values and add
`_julewire_truncation` metadata before later processors or destinations see the
affected field or section.

| Setting | Default |
| --- | --- |
| `max_depth` | `Julewire::Serializer::DEFAULT_MAX_DEPTH` |
| `max_hash_keys` | `Julewire::Serializer::DEFAULT_MAX_HASH_KEYS` |
| `max_array_items` | `Julewire::Serializer::DEFAULT_MAX_ARRAY_ITEMS` |
| `max_string_bytes` | `Julewire::Serializer::DEFAULT_MAX_STRING_BYTES` |

Override these only when the redaction walk must be tighter or looser than
core's default serializer bounds:

```ruby
Julewire::Redaction.configure do |config|
  config.max_depth = 8
  config.max_hash_keys = 1_000
  config.max_array_items = 1_000
  config.max_string_bytes = 16_384
end
```

`max_depth` must be positive. The other limits must be non-negative integers.

## Per-Processor Options

Global configuration is only the default. A processor registration can override
the same options:

```ruby
Julewire.configure do |config|
  config.processors.prepend(
    :redaction,
    %i[password api_key],
    mask: "[SECRET]",
    string_values: false,
    on_error: :fail_closed
  )
end
```

Registration options:

```ruby
config.processors.use(
  :redaction,
  filters,
  mask: "[FILTERED]",
  max_array_items: 1_000,
  max_depth: 8,
  max_hash_keys: 1_000,
  max_string_bytes: 16_384,
  string_values: false,
  authorization_header: true
)
```
