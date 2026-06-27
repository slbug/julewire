# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestConfiguration < Minitest::Test
    cover Julewire::Core::Configuration
    cover "Julewire::Core::FacadeMethods#config"
    cover "Julewire::Core::FacadeMethods#configure"
    cover "Julewire::Core::Runtime#configure"
    cover "Julewire::Core::Runtime#configure_transaction"
    cover "Julewire::Core::Runtime#labels"
    cover Julewire::Core::Destinations::Registry
    cover Julewire::Core::Fields::StaticLabels
    cover Julewire::Core::Processing::ProcessorRegistry
    class CapturingFormatter
      attr_reader :records

      def initialize
        @records = []
      end

      def call(record)
        records << record
        { line: "formatted" }
      end
    end

    def test_configure_sets_formatter_output_and_processor_order
      output = StringIO.new
      formatter = CapturingFormatter.new

      configure_order_pipeline(formatter, output)

      Julewire.emit(message: "hello")

      assert_equal({ "line" => "formatted" }, JSON.parse(output.string))
      assert_equal %w[first second], formatter.records.first.dig(:payload, :order)
    end

    def test_configure_requires_a_block
      error = assert_raises(ArgumentError) { Julewire.configure }

      assert_equal "Julewire.configure requires a block", error.message
    end

    def test_configuration_has_no_default_processors
      assert_empty Julewire.config.processors.to_a
    end

    def test_configuration_defaults_are_explicit
      config = Julewire::Core::Configuration.new

      assert_instance_of Julewire::Core::Destinations::Registry, config.destinations
      assert_instance_of Julewire::Core::Fields::StaticLabels, config.labels
      assert_instance_of Julewire::Core::Processing::ProcessorRegistry, config.processors
      assert_false config.emit_non_standard_exception_summaries
      assert_equal Julewire::Core::MAX_BACKTRACE_LINES, config.error_backtrace_lines
      assert_equal :debug, config.level
      assert_nil config.on_drop
      assert_nil config.on_failure
      assert_equal 1, config.pipeline_close_timeout
    end

    def test_configuration_copy_preserves_non_default_scalar_and_callback_options
      on_drop = ->(*) {}
      on_failure = ->(*) {}
      config = Julewire::Core::Configuration.new(
        emit_non_standard_exception_summaries: true,
        error_backtrace_lines: 3,
        level: :error,
        on_drop: on_drop,
        on_failure: on_failure,
        pipeline_close_timeout: 0.25
      )

      copy = config.copy

      refute_same config, copy
      assert_predicate config, :emit_non_standard_exception_summaries
      assert_predicate copy, :emit_non_standard_exception_summaries
      assert_equal 3, copy.error_backtrace_lines
      assert_equal :error, copy.level
      assert_same on_drop, copy.on_drop
      assert_same on_failure, copy.on_failure
      assert_in_delta 0.25, copy.pipeline_close_timeout
    end

    def test_configuration_build_pipeline_uses_explicit_invalid_severity_reporter
      reports = []
      reporter = Object.new
      reporter.define_singleton_method(:call) { |value| reports << value }
      config = Julewire::Core::Configuration.new
      configure_destination(config, output: StringIO.new)

      config.build_pipeline(invalid_severity_reporter: reporter).emit(severity: Object.new, message: "bad")

      assert_equal 1, reports.length
      assert_instance_of Object, reports.fetch(0)
    end

    def test_configuration_build_pipeline_default_reports_invalid_severities_to_runtime_counter
      reporter = Julewire::Core::Diagnostics::InvalidSeverityReporter
      counter = reporter.counter
      config = Julewire::Core::Configuration.new
      configure_destination(config, output: StringIO.new)

      counter.reset!
      with_overridden_singleton_method(reporter, :counter, proc { counter }) do
        with_overridden_singleton_method(reporter, :warn_once, proc { |_metadata| }) do
          config.build_pipeline.emit(severity: Object.new, message: "bad severity")
        end
      end

      assert_equal({ count: 1 }, counter.health)
    ensure
      counter&.reset!
    end

    def test_configuration_rejects_unknown_constructor_options
      error = assert_raises(ArgumentError) do
        Julewire::Core::Configuration.new(unknown: true)
      end

      assert_equal "unknown configuration options: unknown", error.message
    end

    def test_configuration_normalizes_level_before_it_becomes_active
      config = Julewire.configure do |next_config|
        next_config.level = "INFO"
      end

      assert_equal :info, config.level

      config = Julewire.configure do |next_config|
        next_config.level = 1
      end

      assert_equal :info, config.level
    end

    def test_configuration_rejects_invalid_error_backtrace_lines
      error = assert_raises(ArgumentError) do
        Julewire.configure do |config|
          config.error_backtrace_lines = -1
        end
      end

      assert_equal "error_backtrace_lines must be a non-negative Integer", error.message
    end

    def test_configuration_validate_returns_self
      config = Julewire::Core::Configuration.new

      assert_same config, config.validate!
    end

    def test_configuration_validate_rejects_invalid_pipeline_close_timeout
      config = Julewire::Core::Configuration.new
      config.pipeline_close_timeout = Float::INFINITY

      error = assert_raises(ArgumentError) { config.validate! }

      assert_equal "pipeline_close_timeout must be nil or a non-negative finite Numeric", error.message
    end

    def test_configuration_validate_rejects_invalid_level
      config = Julewire::Core::Configuration.new
      config.level = :unsupported

      error = assert_raises(ArgumentError) { config.validate! }

      assert_equal "unsupported severity: :unsupported", error.message
    end

    def test_configuration_snapshot_is_frozen_normalized_copy
      config = Julewire::Core::Configuration.new
      config.level = "INFO"

      snapshot = config.snapshot

      refute_same config, snapshot
      assert_predicate snapshot, :frozen?
      assert_equal :info, snapshot.level
      assert_equal "INFO", config.level

      config.level = :error

      assert_equal :info, snapshot.level
    end

    def test_configure_rejects_invalid_max_record_bytes
      error = assert_raises(ArgumentError) do
        Julewire.configure do |config|
          configure_destination(config, output: Julewire::Testing::NullOutput.new, max_record_bytes: 0)
        end
      end

      assert_equal "max_record_bytes must be nil or a positive Integer", error.message
    end

    def test_error_backtrace_lines_zero_omits_backtraces_from_record_and_formatter_shapes
      output = StringIO.new
      error = RuntimeError.new("boom")
      error.set_backtrace(["app.rb:1"])

      Julewire.configure do |config|
        config.error_backtrace_lines = 0
        configure_destination(config, output: output)
      end

      Julewire.emit(error: error, payload: { nested_error: error })

      record = JSON.parse(output.string)

      refute_includes record.fetch("error"), "backtrace"
      refute_includes record.dig("payload", "nested_error"), "backtrace"
    end

    def test_error_backtrace_lines_zero_applies_to_execution_summaries
      output = StringIO.new
      error = RuntimeError.new("boom")

      Julewire.configure do |config|
        config.error_backtrace_lines = 0
        configure_destination(config, output: output)
      end

      assert_raises(RuntimeError) do
        Julewire.with_execution(type: :operation) do
          raise error
        end
      end

      summary = JSON.parse(output.string)

      refute_includes summary.fetch("error"), "backtrace"
    end

    def test_configure_rejects_invalid_extension_contracts
      invalid_values = {
        on_drop: ->(config) { config.on_drop = Object.new },
        on_failure: ->(config) { config.on_failure = Object.new },
        formatter: ->(config) { configure_destination(config, formatter: Object.new, output: StringIO.new) },
        output: ->(config) { configure_destination(config, output: Object.new) }
      }

      invalid_values.each do |name, assign|
        error = assert_raises(ArgumentError, name.to_s) do
          Julewire.configure(&assign)
        end

        assert_match(/respond to #(call|write)/, error.message)
      end
    end

    def test_configuration_validates_callback_names_directly
      on_drop_error = assert_raises(ArgumentError) do
        Core::Configuration.new(on_drop: Object.new).validate!
      end
      on_failure_error = assert_raises(ArgumentError) do
        Core::Configuration.new(on_failure: Object.new).validate!
      end

      assert_equal "on_drop must respond to #call", on_drop_error.message
      assert_equal "on_failure must respond to #call", on_failure_error.message
    end

    def test_active_configuration_is_read_only_after_configure
      output = StringIO.new

      config = Julewire.configure do |next_config|
        configure_destination(next_config, output: output)
        next_config.labels.add(service: "core")
      end

      assert_predicate config, :frozen?
      assert_instance_of Julewire::Core::Configuration, config
      assert_raises(FrozenError) { Julewire.config.level = :fatal }
      assert_raises(FrozenError) { Julewire.config.destinations.use(:late, output: StringIO.new) }
      assert_raises(FrozenError) { Julewire.config.labels.add(late: true) }
      assert_raises(FrozenError) { Julewire.config.processors.use(->(record) { record }) }
      assert_raises(FrozenError) { Julewire.labels.add(late: true) }

      Julewire.emit(severity: :debug, message: "still debug")
      record = JSON.parse(output.string)

      assert_equal "debug", record.fetch("severity")
      assert_equal({ "service" => "core" }, record.fetch("labels"))
    end

    def test_static_labels_mutators_copy_and_freeze_like_ruby_objects
      labels = Julewire::Core::Fields::StaticLabels.new

      assert_same labels, labels.add(service: "core")
      copy = labels.to_h
      copy[:service] = "mutated"

      assert_equal({ service: "core" }, labels.to_h)
      assert_same labels, labels.remove(:service)
      assert_empty labels.to_h
      assert_same labels, labels.freeze
      assert_predicate labels, :frozen?
    end

    def test_configuration_labels_reject_non_hash_values
      error = assert_raises(ArgumentError) do
        Julewire.configure do |config|
          config.labels.add("service")
        end
      end

      assert_equal "fields must be a Hash", error.message
    end

    def test_processor_class_can_be_configured
      formatter = CapturingFormatter.new

      Julewire.configure do |config|
        configure_destination(config, formatter: formatter, output: Julewire::Testing::NullOutput.new)
        config.processors.use TestPayloadProcessor, key: :credential, value: "processed"
      end

      Julewire.emit(payload: { credential: "secret", token: "visible" })

      assert_equal "processed", formatter.records.first.dig(:payload, :credential)
      assert_equal "visible", formatter.records.first.dig(:payload, :token)
    end

    def test_with_execution_emits_raw_summary_record_by_default
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      Julewire.with_execution(type: :operation, fields: { operation_id: "op-1" }) do
        Julewire.context.add(tenant_id: "tenant-1", token: "context-secret")
        Julewire.summary.add(plan: "pro", token: "summary-secret")
      end

      summary = JSON.parse(output.string)

      assert_equal "summary", summary["kind"]
      assert_equal "operation.completed", summary["event"]
      assert_equal "tenant-1", summary.dig("context", "tenant_id")
      assert_equal "context-secret", summary.dig("context", "token")
      assert_equal "pro", summary.dig("payload", "plan")
      assert_equal "summary-secret", summary.dig("payload", "token")
    end

    def test_with_execution_can_skip_summary_emission
      output = StringIO.new

      Julewire.configure do |config|
        configure_destination(config, output: output)
      end

      Julewire.with_execution(type: :active_job, emit_summary: false) do
        Julewire.summary.add(job_class: "ExampleJob")
      end

      assert_empty output.string
    end

    def test_failed_configure_does_not_replace_active_configuration_or_pipeline
      output = StringIO.new
      old_config = configure_default_output(output)

      error = assert_configure_with_default_output_raises do |config|
        config.labels.add("invalid")
      end

      assert_equal "fields must be a Hash", error.message
      assert_same old_config, Julewire.config

      Julewire.emit(message: "still active")

      assert_includes output.string, "still active"
    end

    private

    def configure_order_pipeline(formatter, output)
      Julewire.configure do |config|
        configure_destination(config, formatter: formatter, output: output)
        config.processors.clear
        config.processors.use do |record|
          record[:payload][:order] = ["first"]
          nil
        end
        config.processors.use do |record|
          order = record.fetch(:payload).fetch(:order)
          record[:payload][:order] = order + ["second"]
          nil
        end
      end
    end
  end
end
