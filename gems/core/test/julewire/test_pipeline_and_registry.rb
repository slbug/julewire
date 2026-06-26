# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestPipelineAndRegistry < Minitest::Test # rubocop:disable Metrics/ClassLength -- Exercises pipeline ordering and registry edges together.
    cover Julewire::Core::Processing::ProcessorChain
    cover Julewire::Core::Processing::ProcessorWrapper

    class CapturingFormatter
      attr_reader :record

      def call(record)
        @record = record
        {}
      end
    end

    class WriteOnlyOutput
      attr_reader :value

      def write(value)
        @value = value
      end
    end

    class FailingOutput
      def write(_value)
        raise "write failed"
      end
    end

    class FailingFormatter
      def call(_record)
        raise "format failed"
      end
    end

    class FailingLabels
      def fetch(_key, _default = nil)
        raise "label merge failed"
      end
    end

    class OrderedProcessor
      def initialize(value:)
        @value = value
      end

      def call(record)
        payload = record.fetch(:payload)
        payload[:order] = payload.fetch(:order, []) + [@value]
        nil
      end
    end

    class IdentityProcessor
      def call(record)
        record
      end
    end

    class PositionalProcessor
      def initialize(key, value)
        @key = key
        @value = value
      end

      def call(record)
        record[:payload][@key] = @value
        nil
      end
    end

    def test_processor_registry_instantiates_class_with_options
      registry = Julewire::Core::Processing::ProcessorRegistry.new

      registry.use TestPayloadProcessor, key: :value, value: "class-option"

      processed = call_processor(registry.to_a.first, test_record(payload: {}))

      assert_equal "class-option", processed.dig(:payload, :value)
    end

    def test_processor_registry_instantiates_class_with_positional_arguments
      registry = Julewire::Core::Processing::ProcessorRegistry.new

      registry.use PositionalProcessor, :token, "[FILTERED]"

      output = StringIO.new
      pipeline = build_pipeline(output: output, processors: registry.to_a)
      pipeline.emit(payload: { name: "visible" })
      processed = JSON.parse(output.string)

      assert_equal "[FILTERED]", processed.dig("payload", "token")
      assert_equal "visible", processed.dig("payload", "name")
    end

    def test_processor_registry_accepts_callable_processor_objects
      registry = Julewire::Core::Processing::ProcessorRegistry.new
      processor = lambda do |record|
        record[:payload][:callable] = true
        nil
      end

      registry.use processor

      processed = call_processor(registry.to_a.first, test_record(payload: {}))

      assert processed.dig(:payload, :callable)
    end

    def test_processor_registry_builds_registered_processor_kind
      kind = :"registered_processor_#{object_id.abs}"
      Julewire::Core::Processing.register(kind) do |key:, value:|
        lambda do |record|
          record[:payload][key] = value
        end
      end

      registry = Julewire::Core::Processing::ProcessorRegistry.new
      registry.use kind, key: :factory, value: "built"

      processed = call_processor(registry.to_a.first, test_record(payload: {}))

      assert_equal "built", processed.dig(:payload, :factory)
    end

    def test_processor_registry_prepends_registered_processor_kind
      kind = :"registered_prepend_processor_#{object_id.abs}"
      Julewire::Core::Processing.register(kind) { |value:| ->(record) { append_processor_order(record, value) } }
      registry = Julewire::Core::Processing::ProcessorRegistry.new

      registry.use kind, value: "use"
      registry.prepend kind, value: "prepend"

      assert_equal %w[prepend use], processor_order_from(registry)
    end

    def test_processor_registry_wraps_on_error_policy
      registry = Julewire::Core::Processing::ProcessorRegistry.new
      processor = ->(_record) {}

      registry.use processor, on_error: :fail_open

      wrapper = registry.to_a.first

      assert_instance_of Julewire::Core::Processing::ProcessorWrapper, wrapper
      assert_equal :fail_open, wrapper.on_error
      assert_nil wrapper.call(test_record(payload: {}))
    end

    def test_processor_registry_rejects_unknown_on_error_policy
      error = assert_raises(ArgumentError) do
        Julewire::Core::Processing::ProcessorRegistry.new.use ->(_record) {}, on_error: :explode
      end

      assert_match "processor on_error", error.message
    end

    def test_processor_wrapper_accepts_string_on_error_policy
      wrapper = Julewire::Core::Processing::ProcessorWrapper.new(->(_record) {}, on_error: "fail_open")

      assert_equal :fail_open, wrapper.on_error
    end

    def test_processor_wrapper_rejects_non_symbolizable_on_error_policy
      error = assert_raises(ArgumentError) do
        Julewire::Core::Processing::ProcessorWrapper.new(->(_record) {}, on_error: Object.new)
      end

      assert_match "processor on_error", error.message
    end

    def test_processor_wrapper_rejects_object_missing_call
      assert_raises_message(ArgumentError, "processor must respond to call") do
        Julewire::Core::Processing::ProcessorWrapper.new(Object.new)
      end
    end

    def test_processor_registry_prepends_processors
      registry = Julewire::Core::Processing::ProcessorRegistry.new

      registry.use { append_processor_order(it, "use") }
      registry.prepend { append_processor_order(it, "prepend") }

      assert_equal %w[prepend use], processor_order_from(registry)
    end

    def test_processor_registry_prepends_processor_classes_with_options
      registry = Julewire::Core::Processing::ProcessorRegistry.new

      registry.use OrderedProcessor, value: "use"
      registry.prepend OrderedProcessor, value: "prepend"

      assert_equal %w[prepend use], processor_order_from(registry)
    end

    def test_processor_registry_prepends_callable_processor_objects
      registry = Julewire::Core::Processing::ProcessorRegistry.new
      use_processor = ->(record) { append_processor_order(record, "use") }
      prepend_processor = ->(record) { append_processor_order(record, "prepend") }

      registry.use use_processor
      registry.prepend prepend_processor

      assert_equal %w[prepend use], processor_order_from(registry)
    end

    def test_processor_registry_rejects_named_processors
      error = assert_raises(ArgumentError) do
        Julewire::Core::Processing::ProcessorRegistry.new.use :named_processor
      end

      assert_match "unknown processor kind :named_processor", error.message
    end

    def test_processor_registry_requires_processor_or_block
      error = assert_raises(ArgumentError) do
        Julewire::Core::Processing::ProcessorRegistry.new.use
      end

      assert_match "processor or block is required", error.message
    end

    def test_processor_registry_rejects_processor_and_block_together
      error = assert_raises(ArgumentError) do
        Julewire::Core::Processing::ProcessorRegistry.new.use(IdentityProcessor.new) { it }
      end

      assert_match "pass processor or block, not both", error.message
    end

    def test_processor_registry_rejects_options_for_processor_objects
      error = assert_raises(ArgumentError) do
        Julewire::Core::Processing::ProcessorRegistry.new.use ->(record) { record }, value: true
      end

      assert_match "processor options require a class", error.message
    end

    def test_processor_registry_rejects_object_missing_call
      assert_registry_rejects_object(Julewire::Core::Processing::ProcessorRegistry.new, "respond to call")
    end

    def test_pipeline_allows_non_standard_errors_from_processors_to_escape
      processor = Class.new do
        def call(_record)
          raise SystemExit, "stop"
        end
      end.new
      pipeline = build_pipeline(output: StringIO.new, processors: [processor])

      assert_raises(SystemExit) do
        pipeline.emit(message: "boom")
      end
    end

    def test_pipeline_processors_mutate_drafts
      formatter = CapturingFormatter.new
      output = Julewire::Core::TestHelpers::NullOutput.new
      processor = lambda do |record|
        record[:payload][:mutated] = true
        nil
      end
      pipeline = build_pipeline(formatter: formatter, output: output, processors: [processor])

      pipeline.emit(payload: {})

      assert formatter.record.dig(:payload, :mutated)
    end

    def test_match_processor_applies_only_matching_rules
      records = []

      output = StringIO.new
      pipeline = build_pipeline(output: output, processors: [slow_sql_match_processor])
      pipeline.emit(event: "sql.query", payload: { duration_ms: 125 })
      records << JSON.parse(output.string)

      output = StringIO.new
      pipeline = build_pipeline(output: output, processors: [slow_sql_match_processor])
      pipeline.emit(event: "sql.query", payload: { duration_ms: 3 })
      records << JSON.parse(output.string)

      assert records.fetch(0).dig("labels", "slow_sql")
      refute records.fetch(1).dig("labels", "slow_sql")
    end

    def test_match_processor_supports_class_patterns
      output = StringIO.new
      processor = Julewire::Match.new do
        on(payload: { attempts: Integer }) do |draft|
          draft[:labels][:counted] = true
        end
      end
      pipeline = build_pipeline(output: output, processors: [processor])

      pipeline.emit(payload: { attempts: 2 })

      record = JSON.parse(output.string)

      assert record.dig("labels", "counted")
    end

    def test_match_processor_can_drop_records
      output = StringIO.new
      processor = Julewire::Match.new do
        on(severity: :debug) { :drop }
      end
      pipeline = build_pipeline(output: output, processors: [processor])

      pipeline.emit(severity: :debug, message: "noise")

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :processor_dropped)
    end

    def test_match_condition_errors_use_pipeline_processor_failure_path
      output = StringIO.new
      processor = Julewire::Match.new do
        on(payload: ->(_value) { raise "condition failed" }) do |draft|
          draft[:labels][:matched] = true
        end
      end
      pipeline = build_pipeline(output: output, processors: [processor])

      pipeline.emit(payload: {})

      record = JSON.parse(output.string)

      assert_equal "julewire.processor_error", record.fetch("event")
      assert_equal 1, pipeline.health.dig(:counts, :processor_error)
      refute_includes output.string, "condition failed"
      refute record.dig("labels", "matched")
    end

    def test_pipeline_drops_records_that_processors_move_below_threshold
      output = StringIO.new
      processor = lambda do |record|
        record[:severity] = :debug
        nil
      end
      pipeline = build_pipeline(level: :warn, output: output, processors: [processor])

      pipeline.emit(severity: :error, message: "downgraded")

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :level_dropped)
    end

    def test_pipeline_counts_processor_dropped_records
      output = StringIO.new
      pipeline = build_pipeline(output: output, processors: [->(_record) { :drop }])

      pipeline.emit(message: "sampled")

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :entered)
      assert_equal 1, pipeline.health.dig(:counts, :processor_dropped)
    end

    def test_pipeline_merges_static_labels_during_raw_record_build
      output = StringIO.new
      pipeline = build_pipeline(output: output, labels: { service: "api", env: "prod" })

      pipeline.emit(labels: { env: "test" }, message: "hello")

      record = JSON.parse(output.string)

      assert_equal "api", record.dig("labels", "service")
      assert_equal "test", record.dig("labels", "env")
    end

    def test_emit_record_still_merges_static_labels_for_prebuilt_records
      output = StringIO.new
      pipeline = build_pipeline(output: output, labels: { service: "api", env: "prod" })
      record = test_record(labels: { env: "test" }, message: "hello")

      pipeline.emit_record(record)

      emitted = JSON.parse(output.string)

      assert_equal "api", emitted.dig("labels", "service")
      assert_equal "test", emitted.dig("labels", "env")
    end

    def test_emit_isolated_input_does_not_merge_current_context
      output = StringIO.new
      pipeline = build_pipeline(output: output)

      Julewire.context.add(ambient: true)
      pipeline.emit_isolated_input(summary_input(context: { scoped: true }))

      emitted = JSON.parse(output.string)

      assert_equal({ "scoped" => true }, emitted.fetch("context"))
    ensure
      Julewire::Core::ContextStore.reset_current!
    end

    def test_emit_isolated_input_keeps_processor_mutation_off_input
      output = StringIO.new
      processor = ->(record) { record[:payload][:processed] = true }
      pipeline = build_pipeline(output: output, processors: [processor])
      input = summary_input(payload: { status: "ok" })

      pipeline.emit_isolated_input(input)

      emitted = JSON.parse(output.string)

      assert emitted.dig("payload", "processed")
      assert_equal({ status: "ok" }, input.fetch(:payload))
    end

    def test_pipeline_ignores_ordinary_processor_return_values
      output = StringIO.new
      processor = lambda do |record|
        record[:payload][:mutated] = true
        "assignment-like return"
      end
      pipeline = build_pipeline(output: output, processors: [processor])

      pipeline.emit(payload: {})

      record = JSON.parse(output.string)

      assert record.dig("payload", "mutated")
      assert_equal 0, pipeline.health.dig(:counts, :processor_error)
    end

    def test_pipeline_processor_error_record_omits_raw_processor_exception_message
      output = StringIO.new
      pipeline = build_pipeline(processors: [->(_record) { raise "secret-token" }], output: output)

      pipeline.emit(message: "hello")

      record = JSON.parse(output.string)

      assert_equal "RuntimeError", record.dig("payload", "error", "class")
      refute_includes record.dig("payload", "error"), "message"
      refute_includes output.string, "secret-token"
      refute_includes output.string, "hello"
    end

    def test_pipeline_writes_to_output_without_flush
      output = WriteOnlyOutput.new
      pipeline = build_pipeline(output: output)

      pipeline.emit(message: "hello")

      assert_includes output.value, "hello"
    end

    def test_pipeline_swallows_output_write_errors
      assert_pipeline_swallows(output: FailingOutput.new)
    end

    def test_pipeline_swallows_formatter_errors
      assert_pipeline_swallows(formatter: FailingFormatter.new)
    end

    def test_emit_record_notifies_failure_without_internal_error_record
      failures = Queue.new
      output = StringIO.new
      pipeline = build_pipeline(on_failure: ->(error, _metadata) { failures << error }, output: output)

      result = pipeline.emit_record(FailingLabels.new)

      assert_nil result
      assert_empty output.string
      assert_match "Julewire::Record", failures.pop.message
    end

    def test_synchronized_output_wraps_plain_output
      buffer = StringIO.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(buffer)
      pipeline = build_pipeline(output: output)

      pipeline.emit(message: "hello")

      assert_includes buffer.string, "hello"
    end

    private

    def append_processor_order(record, value)
      payload = record.fetch(:payload)
      payload[:order] = payload.fetch(:order, []) + [value]
      nil
    end

    def slow_sql_match_processor
      Julewire::Match.new do
        on(event: /^sql\./, payload: { duration_ms: 100.. }) do |draft|
          draft[:labels][:slow_sql] = true
        end
      end
    end

    def processor_order_from(registry)
      registry.to_a.reduce(test_record(payload: {})) do |record, processor|
        call_processor(processor, record)
      end.fetch(:payload).fetch(:order)
    end

    def test_record(input)
      Julewire::Core::Records::Draft.build(input, context: {}, scope: nil).to_record
    end

    def call_processor(processor, record)
      draft = Julewire::Core::Records::Draft.from_record(record, freeze_sections: false)
      result = processor.call(draft)
      return if result == :drop

      result = draft unless result.is_a?(Julewire::Core::Records::Draft)
      result.to_record
    end

    def assert_pipeline_swallows(**)
      pipeline = build_pipeline(output: StringIO.new, **)

      result = pipeline.emit(message: "hello")

      assert_nil result
    end

    def summary_input(context: {}, payload: {})
      {
        timestamp: Time.utc(2026, 1, 1),
        kind: :summary,
        event: "request.completed",
        source: "julewire",
        execution: { type: "request", id: "request-1" },
        context: context,
        carry: {},
        attributes: {},
        labels: {},
        metrics: {},
        payload: payload,
        error: nil
      }
    end
  end

  class TestRegistryMaterialization < Minitest::Test
    def test_processor_registry_materializes_fresh_class_instances
      registry = Julewire::Core::Processing::ProcessorRegistry.new
      processor_class = Class.new do
        def call(_record)
          self
        end
      end
      registry.use processor_class

      first = registry.to_a.first
      second = registry.copy.to_a.first

      refute_same first, second
      assert_instance_of Julewire::Core::Processing::ProcessorWrapper, first
      assert_instance_of Julewire::Core::Processing::ProcessorWrapper, second
      refute_same first.call(nil), second.call(nil)
    end

    def test_processor_registry_keeps_callable_objects_by_reference
      registry = Julewire::Core::Processing::ProcessorRegistry.new
      processor = ->(record) { record }
      registry.use processor

      record = Object.new

      assert_same record, registry.copy.to_a.first.call(record)
    end
  end

  class TestPipelineLifecycle < Minitest::Test
    class ArgumentErrorFlushOutput < Core::Destinations::SynchronizedOutput
      attr_reader :calls, :flush_timeout

      def initialize
        super(StringIO.new)
        @calls = 0
      end

      def flush(timeout: nil)
        @calls += 1
        @flush_timeout = timeout
        raise ArgumentError, "bad flush #{timeout.inspect}"
      end
    end

    def test_emit_record_applies_level_threshold_to_prebuilt_records
      output = StringIO.new
      pipeline = build_pipeline(level: :warn, output: output)

      record = Julewire::Core::Records::Draft.build(
        { severity: :debug, labels: {}, payload: {} },
        context: {},
        scope: nil
      ).to_record
      result = pipeline.emit_record(record)

      assert_nil result
      assert_empty output.string
    end

    def test_pipeline_lifecycle_does_not_retry_output_argument_errors
      failures = Queue.new
      output = ArgumentErrorFlushOutput.new
      pipeline = build_pipeline(on_failure: ->(error, _metadata) { failures << error }, output: output)

      refute pipeline.flush(timeout: 0.25)

      assert_equal 1, output.calls
      assert_in_delta 0.25, output.flush_timeout
      assert_match(/\Abad flush /, failures.pop.message)
    end
  end
end
