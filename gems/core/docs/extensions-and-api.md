# Extensions and API

Core extension contracts are intentionally Ruby-ish: small objects, `call`,
`write`, named destinations, and optional lifecycle methods.

`contracts.md` is the contract-tier source of truth. This page adds usage
detail for extension and integration authors.

Core uses duck typing. Configuration-time checks only require the expected
method names (`call`, `write`, `emit`, `name`). Arity, keyword, and return-value
mistakes are contained when the extension is invoked and are reported through
small health counters where possible.

## Processors

Processors respond to:

```ruby
processor.call(draft)
```

They receive the current `Julewire::RecordDraft`. Public `Julewire.emit`
input is defensive; processors own the mutable draft until the final immutable
record boundary.

Allowed processor returns:

```ruby
nil                         # draft was mutated in place or unchanged
draft                       # explicit draft return
:drop                       # stop delivery
anything else               # ignored; current draft continues
```

Mutate the draft for ordinary enrichment:

```ruby
draft[:severity] = :warn
draft[:payload][:sampled] = true
```

Draft sections are owned by the processor pipeline, so direct mutation is the
primary processor API:

```ruby
draft.fetch(:context).fetch(:account)[:id] = "changed"
```

Use transform helpers when replacing values or sections. They invalidate cached
records and keep execution lineage when execution identity is unchanged:

```ruby
draft.transform_field!(:severity) { :warn }
draft.transform_section!(:payload) { |payload| payload.merge(sampled: true) }
```

Use `transform_record!` for whole-record replacement transforms:

```ruby
draft.transform_record! { |data| redact(data) }
```

Do not call `to_record` and then mutate a fetched section in place; direct
section mutation cannot invalidate an already-cached immutable record.

Whole-record transforms receive core-owned draft data. Return a normalized
record hash; the pipeline validates it when the draft becomes immutable. Values
set on a draft may be frozen at that boundary.

Class entries pass positional and keyword constructor arguments to the
processor class. Register an already-built object when the application owns the
instance lifecycle.

```ruby
class AddAttribute
  def call(draft)
    draft[:attributes][:app] = { processed: true }
  end
end

Julewire.configure do |config|
  config.processors.use AddTag
end
```

For simple predicate policies, `Julewire::Match` is a processor:

```ruby
config.processors.use Julewire::Match.new do
  on(event: /^active_record\./, payload: { duration_ms: 100.. }) do |draft|
    draft[:labels][:slow_sql] = true
  end

  on(severity: :debug) { :drop }
end
```

For deterministic head sampling, use the registered `:sampling` processor:

```ruby
config.processors.use(
  :sampling,
  rate: 0.1,
  key: ->(draft) { draft.lineage.root_reference&.fetch(:id, nil) }
)
```

The default key uses execution/root identifiers, then `context.request_id`, then
deterministic record fields. A custom `key:` callable returning `nil` drops the
record. `Julewire::Sampling.keep?(rate:, key:)` exposes the same deterministic
rate decision for custom processor and destination policies.

Processor exceptions are contained according to the registration policy.
The default is `on_error: :fail_closed`: core attempts to emit a minimal
`julewire.processor_error` record, the original record is not delivered, and
later processors are not run. Use `on_error: :fail_open` for non-critical
enrichment processors that should record the failure, keep the current draft,
and continue. Use `on_error: :drop` when a failing processor should suppress
the record. `on_error:` is a registry option, not a processor constructor
keyword.

Non-raising draft corruption is detected at the final immutable
`Julewire::Record` boundary and contained as an `emit_record` failure
without per-processor attribution.

Processors can inspect execution lineage before the default formatter strips it
from public output. Promote only the pieces you want to expose:

```ruby
config.processors.use do |draft|
  root_id = draft.lineage.root_reference&.fetch(:id, nil)
  ancestor_count = draft.lineage.ancestors.length

  draft[:labels][:root_execution_id] = root_id if root_id
  draft[:payload][:ancestor_count] = ancestor_count
end
```

Registry methods:

```ruby
config.processors.use ProcessorClass
config.processors.use ProcessorClass, "constructor-arg", enabled: true
config.processors.use EnrichmentProcessor, on_error: :fail_open
config.processors.prepend FirstProcessor
config.processors.prepend(:redaction, on_error: :fail_closed)
config.processors.clear
```

Class entries are instantiated at configure time. Stateful processors should be
designed with that lifecycle in mind.
Integration gems may register processor kinds; applications wire them through
the same registry instead of constructing the common processor object directly.
Processor kind names are part of each integration's extension contract.

## Emit Input Lifecycle

Application emit input crosses a few small objects before it becomes a draft:

| Step | Owner | Job |
| ---- | ----- | --- |
| Facade merge | `Core.emit_input` | Combine positional input and keyword fields without normalizing app objects. |
| Lazy block | `Records::LazyEmitInput` | Keep block-built payloads lazy until the level gate passes and preserve eager severity helpers. |
| Threshold peek | `Records::RawInput` | Read severity, source, and event from raw input without building a record. |
| Draft build | `Draft::BuildInput` | Split raw input into normalized top-level fields plus payload. |

This split keeps below-threshold eager input and lazy blocks cheap while the
final immutable `Record` boundary still validates the full shape.

## Formatters

Formatters respond to:

```ruby
formatter.call(record)
```

They return a payload object. The default formatter is
`Julewire::RecordFormatter`, which returns a public projection of the record. It
omits internal keys such as `:carry` and execution lineage internals.
`Julewire::Core::Records::PublicProjection.public_execution` exposes the same
execution projection without building the full output hash.

Custom formatters receive container-frozen `Julewire::Record` objects,
including the top-level `:carry` section. Hashes, arrays, and copied strings
inside the record are frozen; arbitrary app objects inside fields are still
object references. Use `record.to_h` for a mutable hash copy.
Formatters are responsible for destination-specific shape and must not mutate
the record; redaction policy belongs in processors or application code before
formatting.

## Encoders

Encoders respond to:

```ruby
encoder.call(payload)
```

They receive formatter output and return the string written to the destination
output. The default encoder is `Julewire::JsonEncoder`, which writes one
serialized JSON object plus a newline. It applies Julewire serialization,
including JSON-safe primitives, string keys, bounds, and empty-field
compaction, before calling `JSON.generate`. `Julewire::TextEncoder` renders a
console payload or pre-rendered string as one text line.

Formatters own shape. Encoders own serialization and bytes. Keep provider
mapping, field names, and record projection in formatters; keep JSON, Oj, YAML,
raw text, or other byte encoding decisions in encoders.

## Destinations

Direct core destinations pair one formatter, one encoder, and one output:

```ruby
config.destinations.use(
  :json_stdout,
  formatter: Julewire::RecordFormatter.new,
  encoder: Julewire::JsonEncoder.new,
  output: $stdout
)
```

Integration gems may register destination kinds. Use those through the same
runtime registry:

```ruby
config.destinations.use(:provider_json, output: $stdout)
config.destinations.use(:transport, formatter: formatter, io: $stdout)
```

Destination kind names are part of each integration's extension contract. A
leaf gem may also claim a familiar kind such as `:default` when it deliberately
changes that destination's runtime behavior.

When no destinations are configured, core runs in no-output mode and increments
`health[:pipeline][:counts][:no_output_dropped]`.

Destination names must be unique. Destination formatters get immutable
`Julewire::Record` objects after processors have run. The destination
boundary freezes normalized record containers so all formatters see the same
consistent container shape.
Use `Julewire::Core::Destinations.normalize_name` when custom destination
adapters accept a user-provided destination name.
Encoders turn formatter payload objects into strings for direct destinations.
Destination `on_failure` and `on_drop` callbacks inherit from global callbacks
unless overridden in `config.destinations.use`.
`processors:` may be passed to `config.destinations.use` for destination-local
policy. Those processors run after global processors and before that destination
formats the record. Their drops and failures are scoped to that destination.

Custom destinations can bypass the built-in formatter/JSON/output destination
and add an object directly:

```ruby
config.destinations.add(MyDestination.new(name: :custom))
```

Custom destinations must respond to `name`, `emit(record)`, `flush(timeout:)`,
`close(timeout:)`, and `health`. `flush` and `close` are successful when they
return without raising unless they return `false`.
`emit(record)` is successful when it returns without raising unless it returns
`false`. A custom destination exception is both a destination failure and a
dropped record; a plain `false` is a rejected record and calls `on_drop` with
`:destination_rejected`.

Custom destinations may also implement `after_fork!` for fork reset and
`resource_identity` when multiple destinations share the same closeable
resource. Transport adapters may expose adapter-specific lifecycle methods such
as `reopen`.

The registered `:tail_sampling` destination kind wraps another destination for
execution-level tail sampling. It buffers execution records until a summary
record arrives, keeps error and slow executions, samples the rest with
`Julewire::Sampling`, and forwards kept records to the wrapped destination:

```ruby
config.destinations.use(
  :tail_sampling,
  destination: Julewire::Core::Destinations::Destination.new(output: $stdout),
  sample_rate: 0.1,
  slow_ms: 250
)
```

## Outputs

Outputs respond to:

```ruby
output.write(string)
```

They may also implement:

```ruby
flush
close
health
```

Output lifecycle hooks are sync and local. Runtime timeouts provide one carried
deadline while core walks destinations. Plain outputs receive the timeout only
when their lifecycle method accepts `timeout:` or `**kwargs`; core still cannot
interrupt blocking raw output code. After the first attempted resource,
exhausted deadlines skip later resources. Custom destinations own async drain,
retry, reopen targets, rotation, and timeout-aware shutdown.

Plain output writes are successful when `write` returns without raising and does
not return `false`. A plain `false` is treated as a rejected write. A rejection
is a dropped record at the core destination boundary: the destination increments
`output_rejected` and calls `on_drop` with `:output_rejected`. Raise an
exception for ordinary failures.

Custom destinations that need richer backpressure, retry, or partial-accept
semantics should keep that policy inside the destination and expose it through
destination health.

## Utility APIs

`contracts.md` owns the public utility inventory. The notes below cover the
parts with important ownership or boundary rules.

`EncodingSanitizer.call` repairs strings into valid UTF-8. It is intentionally
string-only; passing other objects is a type error.

`FieldSet` is the public helper for integration-owned field hashes. Its
documented surface is:

- `coerce`
- `merge` and `merge!`
- `deep_dup` and `deep_symbolize_keys`
- `frozen_copy`
- `value_for`
- `VALUE_KEY`

`coerce`, `merge`, and `merge!` normalize string keys to symbols and
defensive-copy values before inserting them, so later caller mutation does not
mutate core field containers. Use symbol keys after that boundary. `VALUE_KEY`
is the key used when non-hash field input is wrapped instead of dropped.

Other `FieldSet` singleton helpers are core-internal implementation support and
are not part of the extension contract.

`FieldSet.deep_dup` is intentionally narrow: it copies `Hash`, `Array`, and
mutable `String` values, relies on Ruby's hash-key string safety for string
keys, and handles cycles. Arbitrary mutable objects remain caller-owned.
Encoders and transport boundaries that need pure log-safe data should use
`Serializer.call` there.

`RecordFieldTransform` walks core's normalized record containers with
`BoundedTransform`. It owns record-shape policy only; processors supply the
actual filtering or replacement policy.

`Carrier` serializes propagation envelopes into flat string carriers for
external boundaries. It is provider-neutral and does not parse or synthesize
external headers. Use `max_bytes:` to leave a carrier unchanged and return
`nil` when the serialized envelope is too large for the target boundary.

`Julewire::RecordDraft.build` is the raw-input construction path used by core and
integration code. `Julewire::RecordDraft#to_record` freezes the final normalized data into
an immutable `Record` for formatters and destinations. `Record` is not a raw
input builder; it is the read-only destination boundary. Use
`Record.from_normalized_hash` only when an extension already owns a complete
symbol-key normalized record hash and needs the immutable destination shape.
That path validates the strict internal contract; it does not clean up
JSON-style or user-input hashes. Use `RecordDraft.build` at raw boundaries.

## Public Facade

`contracts.md` owns the public facade inventory. This section covers usage
details that extension and integration authors usually need.

Integrations that keep process-local state can register a reset hook with
`Julewire::Core::Integration::Lifecycle.register_after_fork(:integration_name,
component: :component_name) { ... }`. The hook runs after core has refreshed its
own process-local state and after the active pipeline has forwarded
`after_fork!` to destinations.

`Julewire.observe_self!(runtime_name = :default, target: :meta)` starts a
`Julewire::Core::Diagnostics::MetaObserver`. The observer samples one runtime's
health and emits health-change records into another named runtime. Pass
`start: false` and call `sample!` manually when deterministic polling is
preferred.

Framework and provider adapters may also use the core integration SPI. The
`Julewire::Core::Integration` namespace is split by concern:

Health:

- `Integration::Health.record_failure` for contained process-level adapter
  failures.
- `Integration::Health.record_success` for recovery after a successful
  integration operation.
- `Integration::Health.scoped(:name)` for bound process-integration health
  helpers. Pass `runtime:` only when a failure belongs to a known runtime rather
  than a process-level framework edge.

Lifecycle:

- `Integration::Lifecycle.require_optional(path)` for contained optional
  requires.
- `Integration::Lifecycle.register_after_fork(:integration_name,
  component: :component_name) { ... }` for process-local integration state.
- `Integration::IvarState` for idempotent framework subscriber state.
- `Integration::Subscription` for subscriber installs that can update
  configuration and best-effort unsubscribe on reset.
- `Integration::SubscriberInstall` for class-level subscriber `install!`
  implementations that expose `subscriber`, `installed?`, and `reset!`.
- `Integration::EventSubscriber` for integration event subscribers that share
  configuration assignment and contained integration-health `emit` handling.
- `Integration::Settings` for small integration configuration objects with
  deep-copied defaults, assignment-time validation, and optional predicate
  accessors.

`Integration::Settings.setting` validators may be instance method names or
procs; return a normalized value or raise.

Runtime access:

- `Integration::Facade.with_execution` for framework integrations that
  build fresh execution attributes and want the same execution boundary as
  `Julewire.with_execution` without copying already-owned attribute hashes.
- `Integration::Facade.emit` for framework/provider integrations that
  emit already-normalized, adapter-owned record hashes. This is not the
  app-facing `Julewire.emit` input path; integrations should pass explicit
  record keys such as `:event`, `:source`, `:payload`, and `:attributes`.

Owned field overlays:

- `Integration::Facade.with_context`, `with_carry`, `with_attributes`, and
  `with_neutral` for block-scoped, already-normalized, adapter-owned field
  hashes around callback, request, or message processing.
- `Integration::Facade.add_context`, `add_carry`, `add_attributes`, and
  `add_neutral` for already-normalized, adapter-owned field hashes added to the
  current execution or ambient context.
  `add_carry` and `add_neutral` are deliberate symmetry points for integrations
  that need ambient propagation or formatter-coordination fields outside a
  scoped callback.
- `Integration::Facade.add_summary_attributes` and `add_summary_neutral` for
  enriching the current execution summary.
- `Integration::Facade.summary_active?` and `increment_summary_attribute` for
  integrations that observe framework events inside an existing execution and
  need to enrich summary counters without using the application facade.

Payload reads and shaping:

- `Integration::Values::Read.value`, `hash_value`, `nested_value`,
  `path_value`, `first_value`, and `blank?` for defensive reads from hashes,
  framework objects, and indexed payloads.
- `Integration::Values::Shape.timestamp`, `payload_hash`, `hash_or_empty`,
  `append_field`, `append_compact_field`, and `source_location_attributes` for
  common event-payload shaping.
- `Julewire::Core.sentinel(:name)` for private integration sentinels that
  should print readably in failures and diffs.
- `Julewire::Core::Validation` for shared option and byte-limit validation.

`hash_value` is for strict hash reads and only bridges symbol/string key forms.
Use `value`, `nested_value`, or `path_value` for foreign objects that expose
methods or indexed access.

Bounded transforms:

- `Julewire::Core::Serialization::BoundedTransform` when a processor or adapter needs a bounded
  walk with core-compatible depth, array, hash, string, cycle, and truncation
  behavior.
  It can insert `_julewire_truncation` metadata before the final encoder sees
  the payload.
- `Julewire::Serializer.truncation_metadata` and serializer truncation
  constants when an adapter must emit core-compatible truncation markers before
  handing data back to core.

This SPI is documented support for integration gems, but not a compatibility
freeze. It may change when the ecosystem gets cleaner. `contracts.md` is the
source of truth for the current tier inventory.

## Extension Contract Tests

Extensions can require `julewire/core/testing` for small test primitives:

- `Julewire::Testing::CaptureDestination`
- `Julewire::Testing::NullOutput`
- `Julewire::Testing.configure_capture_destination`
- `Julewire::Testing::Chaos`
- `Julewire::Testing::Contracts`
- `Julewire::Testing::Coverage`

These helpers are shipped support for Julewire extension and integration gems,
not runtime application API.

`Julewire::Testing::Chaos.assert_contained(test_context) { |error| ... }`
runs a small `StandardError` corpus through containment checks. Use it for
extension paths that promise to absorb formatter, processor, destination, or
subscriber failures.
`Julewire::Testing::Chaos.assert_core_runtime_containment(test_context)` runs
the same corpus through core's curated runtime containment surfaces: processors,
formatters, encoders, outputs, callbacks, and lifecycle hooks.
`Julewire::Testing::Chaos.assert_destination_chaos_contract(...)` runs the
same corpus through a destination's formatter, encoder, output or transport,
and callback containment paths using destination builders supplied by the
extension test.
`Julewire::Testing::Chaos.assert_emitter_chaos_contract(...)` runs the same
corpus through a subscriber/listener-style entrypoint while the extension test
keeps ownership of framework-shaped failing inputs.
`Julewire::Testing::Chaos.catalog { ... }` builds a deterministic component
catalog, and `assert_discovered_chaos_contracts(...)` runs the corpus through
registered processor, formatter, encoder, destination, subscriber, and listener
entries. Use it when an extension can describe its containment surfaces without
reflecting over framework internals.
`Julewire::Testing::Chaos.raiser(error)` builds a callable that raises the
supplied error.

`Julewire::Testing::Contracts` contains shared extension assertions.
`contracts.md` owns the current helper inventory.

Contract helper tiers:

- Component contracts (`processor`, `formatter`, `destination`,
  `record_draft`, record shape/source) are the documented extension test surface.
- Runtime, execution, propagation, integration, validation, truncation, bounded
  transform, and scheduler contracts are integration SPI tests.
- Chaos helpers are shipped support for containment checks. They are intended
  for extension/integration test suites, not app runtime code.

The runtime integration helper emits one point record inside an execution,
adds context, carry, and summary data, flushes, and asserts that destination
health is visible. Extensions provide their own output decoder and record paths,
because formatters may move Julewire fields into a different output shape.

`Julewire::Testing::Coverage` is shipped test support for Julewire
extension gems. It only requires SimpleCov when `Coverage.start!` runs with
`COVERAGE` set, so runtime users do not load coverage dependencies.

The execution-boundary helper gives integration and propagation extensions the
same probe data and lets the extension run it through its own unit of work. The
failure-containment helper verifies that extension failures do not escape
application calls and that health reports degradation.

## Internal or Advanced

These are not ordinary application APIs:

- runtime internals
- pipeline private helpers
- remote-envelope runtime hook
- test helpers

Direct `Julewire::Core::Processing::Pipeline` construction is advanced test and extension plumbing.
Application code should use the `Julewire` facade. A pipeline is built from a
frozen configuration copy; ordinary destination extension goes through
`config.destinations.use`.

`Processing::Pipeline#emit` is the raw-input path and may emit internal Julewire error
records when normalization or processing fails. `Processing::Pipeline#emit_record` is a
trusted extension path: callers must pass a normalized `Julewire::Record`.
It reports contained failures through callbacks and health without recursively
building another internal record.

`Julewire::Core::RuntimeLocator.current=` is an advanced runtime hook for bridge
code. A bridge runtime must support the child-side facade methods it exposes and
the parent-side bridge calls it forwards: `emit_envelope`,
`emit_summary_record`, and `flush`. It is deliberately duck-typed; incompatible
runtimes fail when called, so application code should not replace it casually.

## Remote Envelope Hook

Core exposes the bridge SPI runtime envelope hook used by bridge code. The hook
accepts detached input, context, attributes, carry, neutral data, and a scope
snapshot, then routes them through the active pipeline. Bridge code may pass
`owned: true` only for data decoded from Julewire-owned wire formats.
