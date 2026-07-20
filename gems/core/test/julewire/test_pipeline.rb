# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestPipeline < Minitest::Test
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

    class StringLabelSet
      attr_reader :fields

      def initialize(fields = { "service" => "api" })
        @fields = fields
      end

      def to_h
        @fields
      end
    end

    class LifecycleDestination
      attr_reader :after_fork_count, :close_count, :close_timeout, :flush_count, :flush_timeout, :name

      def initialize(name = :lifecycle)
        @name = name
        @after_fork_count = 0
        @close_count = 0
        @flush_count = 0
      end

      def emit(_record); end

      def flush(timeout: nil) # rubocop:disable Naming/PredicateMethod -- Destination lifecycle SPI returns success.
        @flush_count += 1
        @flush_timeout = timeout
        true
      end

      def after_fork!
        @after_fork_count += 1
        self
      end

      def close(timeout: nil) # rubocop:disable Naming/PredicateMethod -- Destination lifecycle SPI returns success.
        @close_count += 1
        @close_timeout = timeout
        true
      end

      def health = { status: :ok, counts: {} }
    end

    class MetadataRecordish
      def initialize(values)
        @values = values
      end

      def key?(key)
        @values.key?(key)
      end

      def [](key)
        @values[key]
      end
    end

    class BuildForbiddenInput < Hash
      def [](key)
        raise "draft build touched quiet input #{key.inspect}"
      end

      def each
        raise "draft build iterated quiet input"
      end
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
      output = Julewire::Testing::NullOutput.new
      processor = lambda do |record|
        record[:payload][:mutated] = true
        nil
      end
      pipeline = build_pipeline(formatter: formatter, output: output, processors: [processor])

      pipeline.emit(payload: {})

      assert_true formatter.record.dig(:payload, :mutated)
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

    def test_pipeline_counts_level_drop_for_prebuilt_records_after_static_labels
      output = StringIO.new
      pipeline = build_pipeline(level: :warn, labels: { service: "api" }, output: output)
      record = build_record(severity: :debug, message: "below")

      pipeline.emit_record(record)

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :level_dropped)
      assert_equal 0, pipeline.health.dig(:counts, :entered)
    end

    def test_pipeline_counts_processor_dropped_records
      output = StringIO.new
      pipeline = build_pipeline(output: output, processors: [->(_record) { :drop }])

      pipeline.emit(message: "sampled")

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :entered)
      assert_equal 1, pipeline.health.dig(:counts, :processor_dropped)
      assert_equal 0, pipeline.health.dig(:counts, :processor_error)
      assert_nil pipeline.health.fetch(:last_failure)
    end

    def test_pipeline_merges_static_labels_during_raw_record_build
      output = StringIO.new
      pipeline = build_pipeline(output: output, labels: { service: "api", env: "prod" })

      pipeline.emit(labels: { env: "test" }, message: "hello")

      record = JSON.parse(output.string)

      assert_equal "api", record.dig("labels", "service")
      assert_equal "test", record.dig("labels", "env")
    end

    def test_pipeline_symbolizes_configuration_labels_before_merge
      output = StringIO.new
      configuration = Julewire::Core::Configuration.new
      configure_destination(configuration, output: output)
      labels = StringLabelSet.new
      configuration.instance_variable_set(:@labels, labels)
      pipeline = Julewire::Core::Processing::Pipeline.new(configuration: configuration)

      labels.fields["service"] = "mutated"
      pipeline.emit(message: "hello")

      assert_equal "api", JSON.parse(output.string).dig("labels", "service")
    end

    def test_emit_record_still_merges_static_labels_for_prebuilt_records
      output = StringIO.new
      pipeline = build_pipeline(output: output, labels: { service: "api", env: "prod" })
      record = build_record(labels: { env: "test" }, message: "hello")

      pipeline.emit_record(record)

      emitted = JSON.parse(output.string)

      assert_equal "api", emitted.dig("labels", "service")
      assert_equal "test", emitted.dig("labels", "env")
    end

    def test_emit_fast_record_counts_level_drop_and_stops_before_destinations
      output = StringIO.new
      pipeline = build_pipeline(level: :warn, output: output)
      record = build_record(severity: :debug, message: "below")

      assert_nil pipeline.__send__(:emit_fast_record, record, enforce_level: true)

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :level_dropped)
      assert_equal 0, pipeline.health.dig(:counts, :entered)
    end

    def test_emit_fast_record_can_bypass_level_threshold
      output = StringIO.new
      pipeline = build_pipeline(level: :warn, output: output)
      record = build_record(severity: :debug, message: "below")

      pipeline.__send__(:emit_fast_record, record, enforce_level: false)

      assert_equal "below", JSON.parse(output.string).fetch("message")
      assert_equal 0, pipeline.health.dig(:counts, :level_dropped)
      assert_equal 1, pipeline.health.dig(:counts, :entered)
    end

    def test_emit_record_uses_internal_normalized_record_validator
      output = StringIO.new
      pipeline = build_pipeline(output: output)
      record = build_record(message: "hello")
      shadow = Class.new do
        def self.validate_normalized!(_record)
          raise "wrong record validator"
        end
      end

      with_temporary_pipeline_constant(:Record, shadow) do
        pipeline.emit_record(record)
      end

      assert_equal "hello", JSON.parse(output.string).fetch("message")
    end

    def test_pipeline_raw_input_blocked_defers_lazy_inputs_without_explicit_severity
      pipeline = build_pipeline(level: :warn, output: StringIO.new)

      assert_false pipeline.__send__(:raw_input_blocked?, { message: "lazy" }, enforce_level: true, lazy: true)
      assert_true pipeline.__send__(:raw_input_blocked?, { severity: :debug, message: "quiet" },
                                    enforce_level: true, lazy: true)
      assert_false pipeline.__send__(:raw_input_blocked?, { severity: :debug, message: "quiet" },
                                     enforce_level: false, lazy: false)
    end

    def test_pipeline_build_draft_from_forwards_all_sections
      pipeline = build_pipeline(output: StringIO.new)
      scope = build_execution_scope(type: :job, id: "job-1")
      draft = pipeline.__send__(
        :build_draft_from,
        { message: "hello" },
        input_owned: false,
        context: { request_id: "request-1" },
        neutral: { "job.name": "Worker" },
        attributes: { account_id: "acct-1" },
        carry: { trace_id: "trace-1" },
        scope: scope
      )
      record = draft.to_record

      assert_equal "hello", record.fetch(:message)
      assert_equal "job", record.dig(:execution, :type)
      assert_equal "job-1", record.dig(:execution, :id)
      assert_equal({ request_id: "request-1" }, record.fetch(:context))
      assert_equal({ "job.name": "Worker" }, record.fetch(:neutral))
      assert_equal({ account_id: "acct-1" }, record.fetch(:attributes))
      assert_equal({ trace_id: "trace-1" }, record.fetch(:carry))
    end

    def test_pipeline_build_draft_reads_all_ambient_sections
      formatter = CapturingFormatter.new
      pipeline = build_pipeline(formatter: formatter, output: Julewire::Testing::NullOutput.new)

      Julewire.context.add(request_id: "request-1")
      Julewire.carry.add(trace: { id: "trace-1" })
      Julewire.attributes.add(account: { id: "acct-1" })
      Julewire::Core::Integration::Facade.add_neutral(job: { queue: "critical" })

      pipeline.emit(message: "ambient")

      record = formatter.record

      assert_equal "request-1", record.dig(:context, :request_id)
      assert_equal "trace-1", record.dig(:carry, :trace, :id)
      assert_equal "acct-1", record.dig(:attributes, :account, :id)
      assert_equal "critical", record.dig(:neutral, :job, :queue)
    ensure
      Julewire::Core::ContextStore.reset_current!
    end

    def test_pipeline_build_draft_reads_current_execution_scope
      formatter = CapturingFormatter.new
      pipeline = build_pipeline(formatter: formatter, output: Julewire::Testing::NullOutput.new)

      Julewire.with_execution(type: :job, id: "job-1", emit_summary: false) do
        pipeline.emit(message: "scoped")
      end

      assert_equal "job", formatter.record.dig(:execution, :type)
      assert_equal "job-1", formatter.record.dig(:execution, :id)
    end

    def test_pipeline_build_draft_from_forwards_error_backtrace_limit
      error = RuntimeError.new("boom")
      error.set_backtrace(["app/jobs/report_job.rb:12"])
      configuration = Julewire::Core::Configuration.new
      configure_destination(configuration, output: StringIO.new)
      configuration.error_backtrace_lines = 0
      pipeline = Julewire::Core::Processing::Pipeline.new(configuration: configuration.snapshot)
      draft = pipeline.__send__(
        :build_draft_from,
        { error: error, message: "hello" },
        input_owned: false,
        context: nil,
        neutral: nil,
        attributes: nil,
        carry: nil,
        scope: nil
      )

      refute_includes draft.to_record.fetch(:error), :backtrace
    end

    def test_pipeline_after_fork_resets_health_and_delegates_to_destinations
      destination = TestPipeline::LifecycleDestination.new
      configuration = Julewire::Core::Configuration.new
      configuration.level = :warn
      configuration.destinations.add(destination)
      pipeline = Julewire::Core::Processing::Pipeline.new(configuration: configuration.snapshot)

      pipeline.emit(severity: :debug, message: "quiet")

      assert_equal 1, pipeline.health.dig(:counts, :level_dropped)

      assert_same pipeline, pipeline.after_fork!
      assert_equal 1, destination.after_fork_count
      assert_equal 0, pipeline.health.dig(:counts, :level_dropped)
    end

    def test_pipeline_close_delegates_to_destinations
      destination = TestPipeline::LifecycleDestination.new
      configuration = Julewire::Core::Configuration.new
      configuration.destinations.add(destination)
      pipeline = Julewire::Core::Processing::Pipeline.new(configuration: configuration.snapshot)

      assert_true pipeline.close(timeout: 0.25)

      assert_equal 1, destination.close_count
      assert_operator destination.close_timeout, :<=, 0.25
      assert_operator destination.close_timeout, :>, 0
    end

    def test_pipeline_close_accepts_default_timeout_and_skips_resource_identities
      first = LifecycleDestination.new(:first)
      second = LifecycleDestination.new(:second)
      configuration = Julewire::Core::Configuration.new
      configuration.destinations.add(first)
      configuration.destinations.add(second)
      pipeline = Julewire::Core::Processing::Pipeline.new(configuration: configuration.snapshot)

      assert_true pipeline.close
      assert_equal 1, first.close_count
      assert_nil first.close_timeout

      skip = pipeline.lifecycle_resource_identities

      assert_true pipeline.close(skip_resource_identities: skip)

      assert_equal 1, first.close_count
      assert_equal 1, second.close_count
    end

    def test_emit_isolated_input_merges_static_labels
      output = StringIO.new
      pipeline = build_pipeline(output: output, labels: { service: "api" })

      pipeline.emit_isolated_input(summary_input)

      assert_equal "api", JSON.parse(output.string).dig("labels", "service")
    end

    def test_emit_isolated_input_enforces_level_by_default
      output = StringIO.new
      pipeline = build_pipeline(output: output, level: :warn)

      pipeline.emit_isolated_input(summary_input.merge(severity: :debug))

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :level_dropped)
    end

    def test_emit_isolated_input_enforces_default_info_level_without_explicit_severity
      output = StringIO.new
      pipeline = build_pipeline(output: output, level: :warn)

      pipeline.emit_isolated_input(summary_input)

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :level_dropped)
    end

    def test_emit_isolated_input_drops_default_info_before_building_quiet_input
      output = StringIO.new
      pipeline = build_pipeline(output: output, level: :warn)

      pipeline.emit_isolated_input(BuildForbiddenInput.new)

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :level_dropped)
    end

    def test_emit_isolated_input_allows_high_severity_by_default
      output = StringIO.new
      pipeline = build_pipeline(output: output, level: :error)

      pipeline.emit_isolated_input(summary_input.merge(severity: :fatal))

      assert_equal "fatal", JSON.parse(output.string).fetch("severity")
      assert_equal 0, pipeline.health.dig(:counts, :level_dropped)
    end

    def test_emit_integration_enforces_level_by_default
      output = StringIO.new
      pipeline = build_pipeline(output: output, level: :warn)

      pipeline.emit_integration({ event: "adapter.debug", severity: :debug })

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :level_dropped)
    end

    def test_emit_integration_enforces_default_info_level_without_explicit_severity
      output = StringIO.new
      pipeline = build_pipeline(output: output, level: :warn)

      pipeline.emit_integration({ event: "adapter.info" })

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :level_dropped)
    end

    def test_emit_integration_drops_default_info_before_building_quiet_input
      output = StringIO.new
      pipeline = build_pipeline(output: output, level: :warn)

      pipeline.emit_integration(BuildForbiddenInput.new)

      assert_empty output.string
      assert_equal 1, pipeline.health.dig(:counts, :level_dropped)
    end

    def test_emit_integration_allows_high_severity_by_default
      output = StringIO.new
      pipeline = build_pipeline(output: output, level: :error)

      pipeline.emit_integration({ event: "adapter.fatal", severity: :fatal })

      record = JSON.parse(output.string)

      assert_equal "adapter.fatal", record.fetch("event")
      assert_equal "fatal", record.fetch("severity")
      assert_equal 0, pipeline.health.dig(:counts, :level_dropped)
    end

    def test_pipeline_destination_defaults_use_internal_json_encoder_namespace
      fake_encoder = Class.new do
        def initialize(*)
          raise "wrong encoder namespace"
        end
      end
      Julewire::Core::Processing.const_set(:JsonEncoder, fake_encoder)

      pipeline = build_pipeline(output: StringIO.new)

      pipeline.emit(message: "hello")

      assert_equal 1, pipeline.health.dig(:counts, :entered)
    ensure
      Julewire::Core::Processing.__send__(:remove_const, :JsonEncoder) if Julewire::Core::Processing.const_defined?(
        :JsonEncoder, false
      )
    end

    def test_pipeline_destination_defaults_forward_error_backtrace_limit_to_encoder
      output = StringIO.new
      error = RuntimeError.new("boom")
      error.set_backtrace(["app/jobs/report_job.rb:12"])
      configuration = Julewire::Core::Configuration.new
      configuration.error_backtrace_lines = 0
      configure_destination(configuration, output: output, formatter: ->(_record) { { error: error } })
      pipeline = Julewire::Core::Processing::Pipeline.new(configuration: configuration.snapshot)

      pipeline.emit(message: "hello")

      emitted = JSON.parse(output.string)

      refute_includes emitted.fetch("error"), "backtrace"
      assert_equal "RuntimeError", emitted.dig("error", "class")
    end

    def test_pipeline_destination_defaults_forward_configuration_drop_callback
      drops = Queue.new
      output = StringIO.new
      configuration = Julewire::Core::Configuration.new
      configuration.on_drop = ->(reason, metadata) { drops << [reason, metadata.fetch(:destination)] }
      configure_destination(configuration, output: output, max_record_bytes: 3)
      pipeline = Julewire::Core::Processing::Pipeline.new(configuration: configuration.snapshot)

      pipeline.emit(message: "too large")

      assert_equal %i[record_too_large default], safe_queue_pop(drops)
    end

    def test_pipeline_destination_defaults_forward_configuration_failure_callback
      failures = Queue.new
      configuration = Julewire::Core::Configuration.new
      configuration.on_failure = ->(error, metadata) { failures << [error.message, metadata.fetch(:destination)] }
      configure_destination(configuration, output: FailingOutput.new)
      pipeline = Julewire::Core::Processing::Pipeline.new(configuration: configuration.snapshot)

      pipeline.emit(message: "boom")

      assert_equal ["write failed", :default], safe_queue_pop(failures)
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

      assert_true emitted.dig("payload", "processed")
      assert_equal({ status: "ok" }, input.fetch(:payload))
    end

    def test_emit_isolated_input_rejects_nested_string_keys_before_application_processors
      failures = Queue.new
      seen_events = []
      output = StringIO.new
      pipeline = build_pipeline(
        on_failure: ->(error, _metadata) { failures << error },
        output: output,
        processors: [->(draft) { seen_events << draft.fetch(:event) }]
      )

      pipeline.emit_isolated_input(summary_input(payload: { nested: { "invalid" => true } }))

      failure = safe_queue_pop(failures)
      emitted = JSON.parse(output.string)

      assert_instance_of TypeError, failure
      assert_equal Julewire::Core::Fields::Internal::RECORD_STRING_KEY_ERROR, failure.message
      assert_equal ["julewire.emit_error"], seen_events
      assert_equal "julewire.emit_error", emitted.fetch("event")
      refute_includes output.string, "request.completed"
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

      assert_true record.dig("payload", "mutated")
      assert_equal 0, pipeline.health.dig(:counts, :processor_error)
      assert_equal 1, pipeline.health.dig(:counts, :processor_invalid)
      assert_equal :processor_result, pipeline.health.dig(:last_failure, :phase)
      assert_equal "String", pipeline.health.dig(:last_failure, :result_class)
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

    def test_emit_input_guard_reports_original_exception_in_internal_error_record
      output = StringIO.new
      pipeline = build_pipeline(output: output)

      assert_nil pipeline.__send__(:emit_input_with_guard, { message: "ignored" }, enforce_level: false, lazy: false) {
        raise "build failed"
      }

      record = JSON.parse(output.string)

      assert_equal "julewire.emit_error", record.fetch("event")
      assert_equal "RuntimeError", record.dig("payload", "error", "class")
      assert_equal :emit, pipeline.health.dig(:last_failure, :phase)
    end

    def test_emit_internal_error_record_bypasses_level_threshold
      output = StringIO.new
      pipeline = build_pipeline(level: :fatal, output: output)

      pipeline.__send__(:emit_internal_error_record, RuntimeError.new("boom"))

      record = JSON.parse(output.string)

      assert_equal "julewire.emit_error", record.fetch("event")
      assert_equal "RuntimeError", record.dig("payload", "error", "class")
      assert_equal 1, pipeline.health.dig(:counts, :entered)
      assert_equal 0, pipeline.health.dig(:counts, :level_dropped)
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
      assert_match "Julewire::Record", safe_queue_pop(failures).message
    end

    def test_internal_emit_error_record_failures_are_reported
      failures = Queue.new
      output = StringIO.new
      pipeline = build_pipeline(
        on_failure: ->(error, metadata) { failures << [error.class, metadata.fetch(:phase)] },
        output: output
      )

      with_overridden_singleton_method(
        Julewire::Core::Diagnostics::InternalRecords,
        :emit_error,
        proc { |_error| raise "internal record failed" }
      ) do
        assert_nil pipeline.emit(kind: :unknown, severity: :error, message: "bad adapter")
      end

      assert_empty output.string
      assert_equal [ArgumentError, :emit], safe_queue_pop(failures)
      assert_equal [RuntimeError, :internal_error_record], safe_queue_pop(failures)
      assert_equal :internal_error_record, pipeline.health.dig(:last_failure, :phase)
    end

    def test_emit_without_level_keyword_only_input_does_not_create_empty_message
      output = StringIO.new
      pipeline = build_pipeline(output: output)

      assert_nil pipeline.emit_without_level(event: "system.health", severity: :debug)

      record = JSON.parse(output.string)

      assert_nil record["message"]
      assert_equal "system.health", record.fetch("event")
      assert_equal "debug", record.fetch("severity")
    end

    def test_emit_without_level_preserves_positional_input
      output = StringIO.new
      pipeline = build_pipeline(output: output)

      assert_nil pipeline.emit_without_level("debug message", event: "system.health", severity: :debug)

      record = JSON.parse(output.string)

      assert_equal "debug message", record.fetch("message")
      assert_equal "system.health", record.fetch("event")
      assert_equal "debug", record.fetch("severity")
    end

    def test_emit_without_level_forwards_lazy_blocks
      output = StringIO.new
      pipeline = build_pipeline(output: output)

      assert_nil pipeline.emit_without_level(event: "system.health") { { severity: :debug, message: "lazy" } }

      record = JSON.parse(output.string)

      assert_equal "lazy", record.fetch("message")
      assert_equal "system.health", record.fetch("event")
      assert_equal "debug", record.fetch("severity")
    end

    def test_pipeline_without_static_labels_preserves_owned_integration_labels
      output = StringIO.new
      pipeline = build_pipeline(output: output)
      truncation_key = Julewire::Core::Serialization::Serializer::TRUNCATION_METADATA_KEY.to_sym
      metadata = {
        truncated: true,
        truncated_fields: ["labels"],
        limits: { max_depth: 20, max_string_bytes: 10 }
      }

      assert_nil pipeline.emit_integration({
                                             event: "system.health",
                                             labels: { truncation_key => metadata },
                                             message: "ok",
                                             severity: :info
                                           })

      record = JSON.parse(output.string)
      serialized_metadata = record.dig("labels", truncation_key.to_s)

      assert_true serialized_metadata.fetch("truncated")
      assert_equal ["labels"], serialized_metadata.fetch("truncated_fields")
    end

    def test_pipeline_skips_processor_chain_when_no_processors_are_configured
      output = StringIO.new
      pipeline = build_pipeline(output: output, labels: { service: "api" })
      chain = Object.new
      chain.define_singleton_method(:call) { raise "empty processor chain must not run" }
      pipeline.instance_variable_set(:@processor_chain, chain)

      assert_nil pipeline.emit("hello")

      record = JSON.parse(output.string)

      assert_equal "hello", record.fetch("message")
      assert_equal "api", record.dig("labels", "service")
    end

    def test_pipeline_validates_on_failure_callback_at_initialization
      configuration = Julewire::Core::Configuration.new
      configuration.on_failure = Object.new

      error = assert_raises(ArgumentError) do
        Julewire::Core::Processing::Pipeline.new(configuration: configuration)
      end

      assert_equal "on_failure must respond to #call", error.message
    end

    def test_pipeline_default_invalid_severity_reporter_counts_bad_severities
      output = StringIO.new
      reporter = Class.new do
        attr_reader :values

        def initialize
          @values = []
        end

        def call(value)
          @values << value
        end
      end.new
      pipeline = nil

      with_overridden_singleton_method(
        Julewire::Core::Diagnostics::InvalidSeverityReporter,
        :counter,
        proc { reporter }
      ) do
        pipeline = build_pipeline(output: output)
      end

      bad_severity = Object.new
      pipeline.emit(severity: bad_severity, message: "bad")

      assert_equal [bad_severity], reporter.values
    end

    def test_emit_prepared_draft_failure_reports_prepared_record_metadata
      failures = Queue.new
      pipeline = build_pipeline(on_failure: lambda { |error, metadata|
        failures << [error, metadata]
      }, labels: { service: "api" },
                                output: StringIO.new)
      draft = Julewire::Core::Records::Draft.build(
        { event: "prepared.failure", severity: :info, labels: { env: "test" } },
        context: {},
        scope: nil
      )

      with_overridden_singleton_method(
        pipeline,
        :merge_static_labels,
        proc { |_draft| raise "label merge failed" }
      ) do
        assert_nil pipeline.__send__(:emit_prepared_draft, draft, enforce_level: false)
      end

      error, metadata = safe_queue_pop(failures)

      assert_equal "label merge failed", error.message
      assert_equal :emit_record, metadata.fetch(:phase)
      assert_equal "prepared.failure", metadata.dig(:record_metadata, :event)
      assert_equal :info, metadata.dig(:record_metadata, :severity)
    end

    def test_emit_record_without_destinations_drops_before_validation
      pipeline = build_pipeline

      result = pipeline.emit_record(MetadataRecordish.new(event: "invalid.record"))

      health = pipeline.health

      assert_nil result
      assert_equal :unconfigured, health.fetch(:status)
      assert_equal 1, health.dig(:counts, :no_output_dropped)
      assert_equal 0, health.dig(:counts, :failures)
      assert_nil health.fetch(:last_failure)
    end

    def test_emit_record_success_clears_existing_degradation
      output = StringIO.new
      pipeline = build_pipeline(output: output)

      pipeline.emit_record(MetadataRecordish.new(event: "invalid.record"))

      assert_equal :degraded, pipeline.health.fetch(:status)

      pipeline.emit_record(build_record(message: "recovered"))

      health = pipeline.health

      assert_equal :ok, health.fetch(:status)
      assert_equal 1, health.dig(:counts, :failures)
      assert_equal "recovered", JSON.parse(output.string).fetch("message")
    end

    def test_emit_record_failure_reports_attempted_record_metadata
      failures = Queue.new
      record = MetadataRecordish.new(
        event: "invalid.record",
        labels: { component: "test" },
        logger: "spec",
        severity: :error,
        source: "julewire.test"
      )
      pipeline = build_pipeline(on_failure: ->(_error, metadata) { failures << metadata }, output: StringIO.new)

      pipeline.emit_record(record)

      metadata = safe_queue_pop(failures)

      assert_equal :emit_record, metadata.fetch(:phase)
      assert_equal(
        {
          event: "invalid.record",
          labels: { component: "test" },
          logger: "spec",
          severity: :error,
          source: "julewire.test"
        },
        metadata.fetch(:record_metadata)
      )
    end

    def test_synchronized_output_wraps_plain_output
      buffer = StringIO.new
      output = Julewire::Core::Destinations::SynchronizedOutput.new(buffer)
      pipeline = build_pipeline(output: output)

      pipeline.emit(message: "hello")

      assert_includes buffer.string, "hello"
    end

    private

    def build_record(input)
      Julewire::Core::Records::Draft.build(input, context: {}, scope: nil).to_record
    end

    def with_temporary_pipeline_constant(name, value, &)
      with_temporary_constant(Julewire::Core::Processing::Pipeline, name, value, &)
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

  class TestPipelineLifecycle < Minitest::Test
    cover Julewire::Core::Processing::Pipeline
    cover "Julewire::Core::Processing::Pipeline#flush"
    cover Julewire::Core::Processing::ProcessorRegistry
    cover Julewire::Core::Processing::ProcessorWrapper
    cover Julewire::Match
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

      assert_false pipeline.flush(timeout: 0.25)

      assert_equal 1, output.calls
      assert_operator output.flush_timeout, :<=, 0.25
      assert_operator output.flush_timeout, :>, 0.20
      assert_match(/\Abad flush /, safe_queue_pop(failures).message)
    end

    def test_pipeline_flush_accepts_default_timeout
      destination = TestPipeline::LifecycleDestination.new
      configuration = Julewire::Core::Configuration.new
      configuration.destinations.add(destination)
      pipeline = Julewire::Core::Processing::Pipeline.new(configuration: configuration.snapshot)

      assert_true pipeline.flush
      assert_equal 1, destination.flush_count
      assert_nil destination.flush_timeout
    end
  end
end
