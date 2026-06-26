# Records and Data Policy

Core records are symbol-key hashes before formatting. Public ingress accepts
string or symbol keys defensively. Processors receive a mutable
`Julewire::RecordDraft`; destinations and formatters receive an immutable
`Julewire::Record`. The canonical symbol-key shape is:

```ruby
{
  timestamp: Time.now.utc,
  severity: :info,
  kind: :point,
  event: "log",
  message: "message",
  logger: nil,
  source: nil,
  execution: {},
  context: {},
  carry: {},
  neutral: {},
  attributes: {},
  labels: {},
  payload: {},
  metrics: {},
  error: nil
}
```

Raw input is normalized through `Julewire::RecordDraft.build`, then processors
mutate the draft owned by the current emit. After processors finish, core
validates the draft and freezes it through `Julewire::RecordDraft#to_record`
before destinations and formatters see it. Immutable `Record` objects are not
the public raw-input construction API.

`Julewire::RecordFormatter` turns that normalized record into a public log
projection. It omits internal keys such as `:carry` and execution lineage
internals such as `:depth` and `:root`. Direct core destinations pass formatter
payloads to an encoder. The default encoder serializes, compacts, and writes one
JSON object plus a newline.

Records built from log-safe field values are `Ractor.shareable?` after
finalization. Use `Serializer.call` before crossing ractor, process, or network
boundaries with arbitrary application objects.

## Record Kinds

Core supports:

- `:point` for immediate records from `emit`
- `:summary` for final execution summaries

Unknown kinds are treated as extension bugs and contained as Julewire
normalization failures. They are not silently coerced.

Invalid explicit record severity is treated as caller data quality trouble, not
a logging outage. Core normalizes the record severity to `:info`, writes one
process warning, and counts the normalization in health with value class plus
source/event metadata when available. Level filtering then applies normally, so
an invalid explicit severity can still be dropped when `config.level` is above
`:info`. Configuration severities remain strict.

## Structured Sections

Structured sections prefer hashes:

```ruby
execution context carry neutral attributes labels payload metrics
```

Labels are operator metadata, not payload storage. Treat them as non-sensitive,
low-cardinality dimensions that are safe to copy into diagnostic records and
indexes. PII and secrets belong in payload/context fields that a processor can
handle before formatting.

Carry is propagated correlation data. It is present on normalized records and
carried through propagation envelopes, but it is not emitted by the default
formatter and is not execution identity. Use it for small facts that
integrations or formatters need on every record. Put large diagnostic snapshots
in summary payloads instead.

If application code supplies a non-hash value for a structured section, core
preserves it under `:value` instead of dropping it:

```ruby
Julewire.emit(payload: "raw")
# payload: { value: "raw" }
```

Runtime mutation helpers are forgiving for the same reason: logging should not
crash the app.

String keys inside structured sections are normalized to symbols before
processors and destinations run. Encoders and custom destinations may convert
the record to string-key payloads, but the core Ruby record contract stays
symbol-keyed.

## Optional Metadata

`logger` is the logical logger entrypoint, for example `"app"` or
`"billing.audit"`.

`source` is the producer source. Raw application emits leave it `nil`;
integrations should set it.

`timestamp` defaults to `Time.now.utc` when omitted. If caller code supplies an
explicit timestamp, core preserves that value as caller data. Output code that
requires a time-like timestamp should validate or coerce it before export.

## Execution Lineage

Normalized nested executions include cheap relationship metadata:

```ruby
execution: {
  type: "job",
  id: "job-1",
  depth: 2,
  root: { type: "request", id: "req-1" },
  parent: { type: "request", id: "req-1" }
}
```

The full ancestor chain is available through the explicit lineage accessor:

```ruby
record.lineage.ancestors
record.lineage.truncated?
```

Core keeps at most 42 serialized ancestors when that accessor is used. Live
context inheritance still works across all active levels. The default formatter
omits lineage internals and keeps only public execution identity plus caller
fields.

Lineage is still available to processors. Processors may deliberately promote
selected relationship fields into output-facing
sections before formatting:

```ruby
Julewire.configure do |config|
  config.processors.use do |draft|
    root_id = draft.lineage.root_reference&.fetch(:id, nil)
    depth = draft.lineage.depth
    ancestor_count = draft.lineage.ancestors.length

    draft[:labels][:root_execution_id] = root_id if root_id
    draft[:payload][:execution_depth] = depth if depth
    draft[:payload][:ancestor_count] = ancestor_count
  end
end
```

That promotion is explicit policy. Core does not emit full lineage by default.

## Raw by Policy

Core does not redact. Normalized records and propagation envelopes keep
application data raw, including `error.message`, `error.to_s`, payload fields,
context fields, and carry fields. Default formatting may omit carry, but it does
not sanitize values it does emit.

The built-in serializer is an error-pruning layer, not a privacy layer. It makes
values safe to format, caps worst cases, and avoids recursive crashes. It does
not decide which values are secrets.

Put redaction in processors or a separate policy gem before formatting.

## Serializer Bounds

`Julewire::Serializer` applies:

- max nesting depth
- circular reference detection
- max string bytes
- max array items
- max hash keys
- invalid UTF-8 repair
- non-finite float sentinels
- non-primitive numeric strings for `BigDecimal`, `Rational`, `Complex`, etc.
- bounded exception backtraces and cause chains

Truncated containers, containers pruned by `max_depth`, and circular container
references get `_julewire_truncation` metadata. Serializer keys beginning with
`_julewire_` are reserved for core metadata; public field ingress rejects the
truncation marker as a user key. Public Julewire record contracts use symbol keys
internally. Payloads should also use one JSON field name per value; mixed key
types that stringify to the same JSON field are outside the serializer contract.
Long strings use a `...[Truncated]` suffix. User data that already contains that
suffix is preserved as user data.

Unknown objects collapse to safe class markers instead of dumping arbitrary
`inspect` output. If object serialization itself raises, the value becomes a
bounded marker such as `"[Unserializable: RuntimeError]"`.

Exceptions are shaped through `Julewire::Core::Serialization::ExceptionShape`
before encoding:

```ruby
{
  class: "RuntimeError",
  message: "wrapper",
  backtrace: ["app.rb:1:in ..."],
  cause: {
    class: "ArgumentError",
    message: "root"
  }
}
```

Cause chains are bounded and cycle-safe.
Set `config.error_backtrace_lines = 0` to omit `backtrace` fields from
core-shaped exceptions in records and the default formatter output.
The same limit is applied when core receives a core-shaped error hash with
`backtrace` fields at the top level or inside nested `cause` hashes. This keeps
the contract consistent for integrations that pre-shape errors before handing
them to core.

## Internal Error Records

When core can still format and write a replacement record, internal failures may
produce minimal records such as:

- `julewire.emit_error`
- `julewire.processor_error`

Those records intentionally omit original payloads. They include bounded,
serializer-scrubbed exception class details and safe record metadata such as
source, event, severity, logger, and labels when available. They do not include
raw exception messages by default. Use `on_failure` for local diagnostics when
you need the original exception object.
