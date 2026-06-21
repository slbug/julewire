# Contracts

Core has five contract levels. Keep changes honest by deciding which level a
behavior belongs to before preserving or breaking it.

## Public application API

These APIs are for application code and scripts:

- Runtime configuration and lifecycle: `Julewire.configure`,
  `Julewire.config`, `Julewire.reset!`, `Julewire.flush`, `Julewire.close`,
  `Julewire.after_fork!`, and `Julewire.health`.
- `Julewire.runtime` for explicit secondary pipelines with independent
  configuration, destinations, processors, health, and lifecycle.
- `Julewire.labels` for process labels shared by the active runtime.
- `Julewire.emit` and severity helpers: `Julewire.debug`, `Julewire.info`,
  `Julewire.warn`, `Julewire.error`, `Julewire.fatal`, and
  `Julewire.unknown`.
- Execution, context, attributes, carry, and summary facades:
  `Julewire.with_execution`, `Julewire.context`, `Julewire.attributes`,
  `Julewire.carry`, `Julewire.summary`, `Julewire.measure`,
  `Julewire.measure_start`, `Julewire.start_execution`, and
  `Julewire.current_execution` / `Julewire.current_execution?`.
- Local diagnostics and development helpers: `Julewire.doctor`,
  `Julewire.tail`, `Julewire.dev!`, `Julewire.punk!`, and
  `Julewire.observe_self!`.
- Context propagation wrappers: `Julewire.thread` and `Julewire.fiber`.
- Destination configuration through `config.destinations.use`.
- `Julewire::Core::Propagation::Carrier` and `Julewire::Core::Propagation` for explicit
  cross-boundary propagation.

Application-facing logging calls contain Julewire `StandardError` failures.
They do not hide application exceptions.

## Extension contract

These APIs are intentionally available to integration code, but they are not
general application surface:

- `Julewire::RecordDraft` as the processor mutation surface and
  raw-input construction surface used by core and integrations before records
  become immutable. Prefer `transform_field!`, `transform_section!`, and
  `transform_record!` for replacement transforms.
- Immutable `Julewire::Record` instances for destinations and formatters.
- `Julewire::Record::REQUIRED_KEYS` and `HASH_SECTIONS` for processors that
  need to preserve core record shape.
- `record.lineage` for explicit execution lineage access. Normalized record
  data keeps only cheap execution identity; full ancestors are read through the
  lineage accessor.
- `Julewire::Core::Records::PublicProjection`, the public record projection
  used by the default formatter and serializer.
- `Julewire::Core::Records::PublicProjection::INTERNAL_EXECUTION_KEYS` for provider
  formatters that expose a public execution payload.
- Encoder objects that respond to `call(payload)` and return strings for direct
  destinations.
- The five-method destination duck type: `name`, `emit`, `flush`, `close`, and
  `health`.
- `Julewire::Core::Destinations.normalize_name` for destination-name
  normalization shared by destination adapters.
- `Julewire::TailSampling` as a destination wrapper for execution-level tail
  sampling.
- `Julewire::Testing::CaptureDestination`, `Julewire::Testing::NullOutput`,
  `Julewire::Testing.capture`, `Julewire::Testing.configure_capture_destination`,
  `Julewire::Testing::Contracts`, `Julewire::Testing::Chaos`, and
  `Julewire::Testing::Coverage` as extension test support.
- `RuntimeLocator.current.emit_without_level` for host-process integrations
  that already apply their framework's level gate.

Extensions should consume these contracts rather than reaching into pipeline,
runtime, storage, or destination internals.

Testing support is shipped for integration authors, but helper names may still
change when the ecosystem cleanup demands it.

`Julewire::Testing::Contracts` currently ships these shared assertions for
extension and integration gems:

- `assert_julewire_bounded_transform_spi_contract`
- `assert_julewire_deadline_scheduler_spi_contract`
- `assert_julewire_destination_contract`
- `assert_julewire_execution_boundary_contract`
- `assert_julewire_failure_containment_contract`
- `assert_julewire_formatter_contract`
- `assert_julewire_integration_failure_contract`
- `assert_julewire_integration_health_contract`
- `assert_julewire_integration_ivar_state_contract`
- `assert_julewire_integration_payload_contract`
- `assert_julewire_integration_spi_contract`
- `assert_julewire_integration_timestamp_contract`
- `assert_julewire_integration_value_contract`
- `assert_julewire_processor_contract`
- `assert_julewire_propagation_contract`
- `assert_julewire_record_draft_transform_contract`
- `assert_julewire_record_shape_contract`
- `assert_julewire_record_source_contract`
- `assert_julewire_runtime_integration_contract`
- `assert_julewire_truncation_marker_spi_contract`
- `assert_julewire_validation_spi_contract`

`Julewire::Testing::Chaos` currently ships containment helpers for extension
test suites:

- `assert_contained`
- `assert_core_runtime_containment`
- `assert_destination_chaos_contract`
- `assert_discovered_chaos_contracts`
- `assert_emitter_chaos_contract`
- `catalog`
- `raiser`

## Integration SPI

These APIs are for framework, provider, and transport integrations that need a
little more structure than application code. They are public to integrations,
but they are not intended as general application API:

- `Julewire::Core::Integration::Health` for contained process-level
  integration health and scoped health wrappers.
- `Julewire::Core::Integration::Facade` for integration-owned emits,
  execution boundaries, field overlays, and summary enrichment.
- `Julewire::Core::Integration::Values::Read` for hash/object value reads
  including `value`, `hash_value`, `nested_value`, `path_value`,
  `first_value`, and `blank?`.
- `Julewire::Core::Integration::Values::Shape` for normalized timestamps, payload
  normalization, field appends, and source-location shaping.
- `Julewire::Core::Integration::Lifecycle` for optional require containment and
  process-local `after_fork` hooks.
- `Julewire::Core::Integration` helper classes/modules for one-time ivar state,
  subscriber install helpers, event-subscriber health wrappers, config settings
  helpers, and subscription handles.
- `Julewire::Core::Integration::DestinationHealth` for destination-style
  integrations that need Julewire-shaped counters, failure snapshots, and loss
  snapshots without exposing core's internal health cells.
- `Julewire::Core::Destinations::WriteStep` for destination-style integrations
  that reuse core's format, encode, bound, write, and counter sequence while
  keeping their own lifecycle and failure policy.
- `Julewire::Core::CLI::LogFormats` for provider-owned CLI file-tail decoding
  and transcoding formats.
- `Julewire::Core::Processing.register` for integration-owned processor kinds,
  and `Julewire::Core::Processing::RecordFieldTransform` for processors that
  need core's normalized record-section walk while keeping their own filtering
  policy.
- `Julewire::Core::Fields::AttributeKeys` for provider-neutral formatter
  coordination attributes.
- `Julewire::Core::Fields::Bags` for record field-bag capabilities such as
  emitted output sections, transform containers, propagation, and delete-path
  support.
- `Julewire::Core.sentinel(:name)` for readable, frozen identity markers when
  an integration needs a private empty or missing-value sentinel.
- `Julewire::Core.deep_compact_empty` for core-compatible empty-field pruning.
- `Julewire::Core::Scheduling::DeadlineScheduler` for integration-local timeout callbacks
  that need Julewire's fork-reset behavior.
- `Julewire::Core::Scheduling::SharedScheduler` for process-wide main-ractor
  timeouts shared by integrations that should not own separate scheduler
  threads.
- `Julewire::Core::Validation` for shared option and limit validation.
- `Julewire::Core::Serialization::BoundedTransform` for processors and integrations that need
  core-compatible bounded traversal before core serializes the result.
- `Julewire::Core::Diagnostics::CallbackNotifier` and
  `Julewire::Core::Diagnostics::FailureSnapshot` for destination-style
  integrations that need core-compatible callback and health failure shape.
- `Julewire::Core::Records::DisplayMessage` and
  `Julewire::Core::Records::Metadata` for formatters and destination-style
  integrations that need the same display-message fallback or safe record
  coordinates as core.
- `Julewire::Core::Records::Severity` for integrations that normalize
  framework-native levels before handing records to core.
- `Julewire::Serializer.truncation_metadata` and serializer constants that
  define core-compatible truncation markers when an integration must shape
  bounded data before core serializes it.
Integrations may use this SPI when they need to match core behavior exactly.
New SPI use should be covered by either core contract tests or integration
tests that would fail on incompatible core changes.

## Bridge SPI

These APIs are for runtime bridges that need to run Julewire facade calls in a
different Ruby isolation boundary:

- `Julewire::Core::RuntimeLocator.current=` to install the bridge runtime.
- `Julewire::Core::UNSET`, `Julewire::Core.emit_input`, and
  `Julewire::Core::Records::LazyEmitInput` to mirror facade emit semantics
  across an isolation boundary.
- `Julewire::Core::Execution::Boundary` for shared execution boundary behavior.
- `Julewire::Core::ContextStore.current`,
  `Julewire::Core::Fields::ContextProxy`,
  `Julewire::Core::Fields::AttributesProxy`,
  `Julewire::Core::Fields::CarryProxy`, and
  `Julewire::Core::Fields::SummaryProxy` for bridge-local field bags.
- `Julewire::Core::Execution::ScopeSnapshot` for detached execution scope transfer.
- Parent-runtime hooks: `emit_envelope`, `emit_summary_record`, and `flush`.
  `emit_envelope` accepts detached input, context, carry, attributes, neutral,
  scope snapshot, and an `enforce_level:` flag.

Bridge runtimes may expose `emit_without_level` when integration code inside
the bridge has already applied its own level gate. Parent runtime labels,
processors, destinations, and outputs remain parent-owned.

## Internal implementation

These details are intentionally private and can move freely:

- `Runtime`, `Processing::Pipeline`, destination-set, and lifecycle state layout.
- Field stacks, local storage, and ractor lookup internals.
- Counter storage, callback-notifier plumbing, and health implementation
  mechanics.
- Serializer traversal internals and value-copy helpers.

Tests may characterize internal behavior only when it protects a public or
extension contract, such as exception fidelity, cycle safety, fork safety, or
wire-shape stability.
