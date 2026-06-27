# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestProcessorRegistry < Minitest::Test
    cover "Julewire::Core::Processing.build"
    cover "Julewire::Core::Processing.factory_for"
    cover "Julewire::Core::Processing::InvalidResultFailure*"
    cover "Julewire::Core::Processing.normalize_kind"
    cover "Julewire::Core::Processing.register"
    cover Julewire::Core::Processing::Pipeline
    cover "Julewire::Core::Processing::ProcessorChain*"
    cover "Julewire::Core::Processing::Pipeline#after_fork!"
    cover "Julewire::Core::Processing::Pipeline#build_draft"
    cover "Julewire::Core::Processing::Pipeline#build_draft_from"
    cover "Julewire::Core::Processing::Pipeline#build_threshold"
    cover "Julewire::Core::Processing::Pipeline#close"
    cover "Julewire::Core::Processing::Pipeline#destination_defaults"
    cover "Julewire::Core::Processing::Pipeline#emit"
    cover "Julewire::Core::Processing::Pipeline#emit_fast_record"
    cover "Julewire::Core::Processing::Pipeline#emit_input_with_guard"
    cover "Julewire::Core::Processing::Pipeline#emit_internal_error_record"
    cover "Julewire::Core::Processing::Pipeline#emit_prepared_draft"
    cover "Julewire::Core::Processing::Pipeline#emit_processed_draft"
    cover "Julewire::Core::Processing::Pipeline#emit_with_level_check"
    cover "Julewire::Core::Processing::Pipeline#raw_input_blocked?"
    cover Julewire::Core::Processing::ProcessorRegistry
    cover "Julewire::Core::Records::Draft::Builder*"
    cover Julewire::Core::Processing::ProcessorWrapper
    cover Julewire::Match
    class NamedProcessor
      def call(_record); end
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

      processed = call_processor(registry.to_a.first, build_record(payload: {}))

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
      assert_nil processed["message"]
    end

    def test_processor_registry_accepts_callable_processor_objects
      registry = Julewire::Core::Processing::ProcessorRegistry.new
      processor = lambda do |record|
        record[:payload][:callable] = true
        nil
      end

      registry.use processor

      processed = call_processor(registry.to_a.first, build_record(payload: {}))

      assert_true processed.dig(:payload, :callable)
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

      processed = call_processor(registry.to_a.first, build_record(payload: {}))

      assert_equal "built", processed.dig(:payload, :factory)
    end

    def test_sampling_symbolic_factory_configures_real_processor
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
        config.processors.use(:sampling, rate: 1)
      end

      Julewire.emit(message: "sampled")

      assert_equal "sampled", JSON.parse(output.string).fetch("message")
    end

    def test_processor_registry_materializes_factory_with_positional_arguments
      kind = :"registered_positional_processor_#{object_id.abs}"
      Julewire::Core::Processing.register(kind) do |prefix, key:|
        ->(record) { record[:payload][key] = "#{prefix}-factory" }
      end
      registry = Julewire::Core::Processing::ProcessorRegistry.new

      registry.use kind, "positional", key: :factory
      processed = call_processor(registry.to_a.first, build_record(payload: {}))

      assert_equal "positional-factory", processed.dig(:payload, :factory)
    end

    def test_processor_registry_normalizes_string_processor_kinds
      kind = "registered_string_processor_#{object_id.abs}"
      Julewire::Core::Processing.register(kind) { ->(record) { record[:payload][:string_kind] = true } }

      processor = Julewire::Core::Processing.build(kind.to_sym)
      processed = call_processor(processor, build_record(payload: {}))

      assert_true processed.dig(:payload, :string_kind)
    end

    def test_processor_registry_materializes_string_processor_kinds
      kind = "registered_registry_string_processor_#{object_id.abs}"
      Julewire::Core::Processing.register(kind) do |key:|
        ->(record) { record[:payload][key] = "from-registry" }
      end
      registry = Julewire::Core::Processing::ProcessorRegistry.new

      registry.use kind, key: :string_kind
      processed = call_processor(registry.to_a.first, build_record(payload: {}))

      assert_equal "from-registry", processed.dig(:payload, :string_kind)
    end

    def test_processor_registry_accepts_custom_symbolizable_kinds
      name = :"registered_custom_processor_#{object_id.abs}"
      kind = Object.new
      kind.define_singleton_method(:to_sym) { name }
      Julewire::Core::Processing.register(kind) { ->(record) { record[:payload][:custom_kind] = true } }

      processor = Julewire::Core::Processing.build(name)
      processed = call_processor(processor, build_record(payload: {}))

      assert_true processed.dig(:payload, :custom_kind)
    end

    def test_processing_build_rejects_unknown_processor_kind
      kind = :"missing_processor_#{object_id.abs}"

      error = assert_raises(ArgumentError) do
        Julewire::Core::Processing.build(kind)
      end

      assert_equal "unknown processor kind #{kind.inspect}", error.message
    end

    def test_processor_registry_rejects_unknown_symbolizable_processor_kind
      registry = Julewire::Core::Processing::ProcessorRegistry.new
      kind = "missing_registry_processor_#{object_id.abs}"

      error = assert_raises(ArgumentError) do
        registry.use kind
      end

      assert_equal "unknown processor kind #{kind.to_sym.inspect}", error.message
    end

    def test_processor_registry_rejects_constructor_arguments_for_callable_objects
      registry = Julewire::Core::Processing::ProcessorRegistry.new

      error = assert_raises(ArgumentError) do
        registry.use ->(_record) {}, :token
      end

      assert_equal "processor constructor arguments require a class", error.message
    end

    def test_processor_registry_rejects_constructor_options_for_callable_objects
      registry = Julewire::Core::Processing::ProcessorRegistry.new

      error = assert_raises(ArgumentError) do
        registry.use ->(_record) {}, key: :value
      end

      assert_equal "processor options require a class", error.message
    end

    def test_processor_registry_snapshots_symbolizable_factory_kinds
      original_name = :"registered_mutable_processor_#{object_id.abs}"
      next_name = :"registered_mutable_processor_changed_#{object_id.abs}"
      kind = Object.new
      current_name = original_name
      kind.define_singleton_method(:to_sym) { current_name }
      Julewire::Core::Processing.register(original_name) do |key:|
        ->(record) { record[:payload][key] = original_name }
      end
      registry = Julewire::Core::Processing::ProcessorRegistry.new

      registry.use kind, key: :snapshot
      current_name = next_name

      processed = call_processor(registry.to_a.first, build_record(payload: {}))

      assert_equal original_name, processed.dig(:payload, :snapshot)
    end

    def test_processor_registry_builds_immutable_entry_snapshots
      registry = Julewire::Core::Processing::ProcessorRegistry.new
      kind = :"registered_snapshot_processor_#{object_id.abs}"
      Julewire::Core::Processing.register(kind) { |_token, key:| ->(record) { record[:payload][key] = true } }
      arguments = [:token]
      options = { key: :factory, on_error: :fail_open }

      factory_entry = registry.__send__(:build_entry, kind.to_s, arguments, options)
      class_entry = registry.__send__(:build_entry, PositionalProcessor, arguments, options)
      callable_entry = registry.__send__(:build_entry, ->(record) { record }, [], {})

      assert_equal kind, factory_entry.entry
      assert_equal({ key: :factory, on_error: :fail_open }, options)
      assert_equal [:token], arguments
      [factory_entry, class_entry].each do |entry|
        assert_equal [:token], entry.arguments
        assert_predicate entry.arguments, :frozen?
        assert_equal({ key: :factory }, entry.options)
        assert_predicate entry.options, :frozen?
        assert_equal :fail_open, entry.on_error
      end
      assert_equal [], callable_entry.arguments
      assert_predicate callable_entry.arguments, :frozen?
      assert_equal({}, callable_entry.options)
      assert_predicate callable_entry.options, :frozen?

      arguments << :mutated
      options[:key] = :mutated

      assert_equal [:token], factory_entry.arguments
      assert_equal({ key: :factory }, factory_entry.options)
      assert_equal [:token], class_entry.arguments
      assert_equal({ key: :factory }, class_entry.options)
    end

    def test_processor_registry_rejects_invalid_processor_kind_values
      assert_raises_message(ArgumentError, "processor kind is required") do
        Julewire::Core::Processing.register(nil) { ->(_record) {} }
      end

      assert_raises_message(ArgumentError, "processor kind must respond to #to_sym") do
        Julewire::Core::Processing.register(Object.new) { ->(_record) {} }
      end

      assert_raises_message(ArgumentError, "processor kind cannot be empty") do
        Julewire::Core::Processing.register("") { ->(_record) {} }
      end

      bad_symbolizer = Object.new
      bad_symbolizer.define_singleton_method(:to_sym) { "not_a_symbol" }
      assert_raises_message(ArgumentError, "processor kind #to_sym must return a Symbol") do
        Julewire::Core::Processing.register(bad_symbolizer) { ->(_record) {} }
      end
    end

    def test_processor_registry_requires_registered_processor_factory_block
      assert_raises_message(ArgumentError, "processor factory block required") do
        Julewire::Core::Processing.register(:missing_factory)
      end
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
      assert_nil wrapper.call(build_record(payload: {}))
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

    def test_processor_wrapper_defaults_to_fail_closed
      wrapper = Julewire::Core::Processing::ProcessorWrapper.new(->(_record) {})

      assert_equal :fail_closed, wrapper.on_error
    end

    def test_processor_wrapper_reports_wrapped_processor_class_name
      wrapper = Julewire::Core::Processing::ProcessorWrapper.new(NamedProcessor.new)

      assert_equal "Julewire::TestProcessorRegistry::NamedProcessor", wrapper.processor_name
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
      error = assert_raises(ArgumentError) do
        Julewire::Core::Processing::ProcessorRegistry.new.use Object.new
      end

      assert_match "respond to call", error.message
    end

    def test_processor_registry_clear_empties_entries_and_returns_registry
      registry = Julewire::Core::Processing::ProcessorRegistry.new
      registry.use ->(record) { record }

      assert_same registry, registry.clear
      assert_empty registry.to_a
    end

    def test_processor_registry_freeze_returns_registry_and_blocks_mutation
      registry = Julewire::Core::Processing::ProcessorRegistry.new

      assert_same registry, registry.freeze
      assert_predicate registry, :frozen?
      assert_raises(FrozenError) { registry.use(->(record) { record }) }
    end

    private

    def append_processor_order(record, value)
      payload = record.fetch(:payload)
      payload[:order] = payload.fetch(:order, []) + [value]
      nil
    end

    def processor_order_from(registry)
      registry.to_a.reduce(build_record(payload: {})) do |record, processor|
        call_processor(processor, record)
      end.fetch(:payload).fetch(:order)
    end

    def build_record(input)
      Julewire::Core::Records::Draft.build(input, context: {}, scope: nil).to_record
    end

    def call_processor(processor, record)
      draft = Julewire::Core::Records::Draft.from_record(record)
      result = processor.call(draft)
      return if result == :drop

      result = draft unless result.is_a?(Julewire::Core::Records::Draft)
      result.to_record
    end
  end

  class TestRegistryMaterialization < Minitest::Test
    cover Julewire::Core::Processing::Pipeline
    cover Julewire::Core::Processing::ProcessorRegistry
    cover Julewire::Core::Processing::ProcessorWrapper
    cover Julewire::Match
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
end
