# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require_relative "../../../support/testing/coverage"
Julewire::TestSupport::Coverage.start!

require "julewire/core"
require "julewire/core/testing"
require_relative "support/julewire/core/test_helpers"
require_relative "support/julewire/core/test_payload_processor"

require "minitest/autorun"
require "minitest/strict"
require_relative "../../../support/testing/method_override"
require_relative "../../../support/testing/test_reports"
Julewire::TestSupport::TestReports.start!
require_relative "../../../support/mutant/minitest_coverage"
require "timeout"

module Minitest
  class Test
    include Julewire::Core::TestHelpers
    include Julewire::TestSupport::MethodOverride

    def setup
      reset_julewire!
    end

    def safe_thread(*, &block)
      build_safe_thread(block) { |worker| Thread.new(*, &worker) }
    end

    def safe_julewire_thread(*, &block)
      build_safe_thread(block) { |worker| Julewire.thread(*, &worker) }
    end

    def build_safe_thread(block)
      raise ArgumentError, "block required" unless block

      worker = proc do |*thread_arguments|
        Thread.current.abort_on_exception = false
        Thread.current.report_on_exception = false
        block.call(*thread_arguments)
      rescue Exception => e # rubocop:disable Lint/RescueException -- Re-raised by the owning test after bounded join.
        Thread.current.thread_variable_set(:julewire_test_worker_exception, e)
        nil
      end
      yield worker
    end

    def safe_thread_value(thread, timeout: 1)
      unless thread.join(Float(timeout))
        cleanup_thread(thread)

        flunk "thread did not finish within #{timeout} seconds"
      end

      value = thread.value
      error = thread.thread_variable_get(:julewire_test_worker_exception)
      raise error if error

      value
    end

    def safe_thread_values(threads, timeout: 1)
      threads.map { safe_thread_value(it, timeout: timeout) }
    end

    def safe_queue_pop(queue, timeout: 1)
      Timeout.timeout(timeout) { queue.pop }
    end

    def cleanup_thread(thread, timeout: 0)
      return unless thread
      return if thread.join(Float(timeout))

      thread.kill
      thread.join(0.1)
    end

    def assert_raises_message(error_class, message, &)
      error = assert_raises(error_class, &)

      assert_match message, error.message
    end

    def assert_string_truncation_metadata(metadata, fields:, **limits)
      assert_truncation_metadata_keys(metadata, fields: fields, key_style: :string, **limits)
    end

    def assert_symbol_truncation_metadata(metadata, fields:, **limits)
      assert_truncation_metadata_keys(metadata, fields: fields, key_style: :symbol, **limits)
    end

    def assert_truncation_metadata_keys(metadata, fields:, key_style:, **limits)
      key_for = ->(value) { key_style == :string ? value.to_s : value }

      assert_true metadata.fetch(key_for.call(:truncated))
      assert_equal fields, metadata.fetch(key_for.call(:truncated_fields))
      limit_values = metadata.fetch(key_for.call(:limits))

      limits.each do |key, value|
        assert_equal value, limit_values.fetch(key_for.call(key))
      end
    end

    def capture_propagation(type:, execution: {}, context: {}, carry: {}, summary: {})
      envelope = nil

      Julewire.with_execution(type: type, fields: execution) do
        Julewire.context.add(context) unless context.empty?
        Julewire.carry.add(carry) unless carry.empty?
        Julewire.summary.add(summary) unless summary.empty?
        envelope = Julewire::Core::Propagation.capture
      end

      envelope
    end

    def with_julewire_job(&)
      Julewire.with_execution(type: :job, emit_summary: false, &)
    end

    def nonblocking_queue_values(queue) = Array.new(queue.size) { queue.pop(true) }

    def destination_health(name = :default)
      Julewire.health.fetch(:pipeline).fetch(:destinations).fetch(name)
    end

    def queue_callbacks(drops:, failures:)
      {
        on_drop: ->(reason, metadata) { drops << [reason, metadata] },
        on_failure: ->(error, metadata) { failures << [error, metadata] }
      }
    end

    def build_destination(output:, encoder: Julewire::Core::Serialization::JsonEncoder.new,
                          formatter: Julewire::Core::Records::Formatter.new, name: :default,
                          on_drop: nil, on_failure: nil, max_record_bytes: Julewire::Core::DEFAULT_MAX_RECORD_BYTES,
                          close_output: false)
      Julewire::Core::Destinations::Destination.new(
        name: name,
        close_output: close_output,
        encoder: encoder,
        formatter: formatter,
        max_record_bytes: max_record_bytes,
        on_drop: on_drop,
        on_failure: on_failure,
        output: output
      )
    end

    def build_pipeline(output: nil, encoder: Julewire::Core::Serialization::JsonEncoder.new,
                       formatter: Julewire::Core::Records::Formatter.new,
                       on_drop: nil, on_failure: nil, **options)
      configuration = Julewire::Core::Configuration.new
      configuration.on_drop = on_drop
      configuration.on_failure = on_failure
      configuration.level = options.fetch(:level, configuration.level)
      if output
        configure_destination(
          configuration,
          output: output,
          encoder: encoder,
          formatter: formatter,
          max_record_bytes: options.fetch(:max_record_bytes, Julewire::Core::DEFAULT_MAX_RECORD_BYTES)
        )
      end
      Array(options.fetch(:processors, [])).each { configuration.processors.use(it) }
      options.fetch(:labels, {}).then { configuration.labels.add(it) unless it.empty? }

      Julewire::Core::Processing::Pipeline.new(configuration: configuration.snapshot)
    end

    def build_record(input = {}, context: {}, scope: nil, carry: {}, attributes: {})
      Julewire::Core::Records::Draft.build(
        input,
        context: context,
        carry: carry,
        attributes: attributes,
        scope: scope
      ).to_record
    end

    def assert_invalid_utf8_repaired
      repaired = yield invalid_utf8_string

      assert_equal "token ?", repaired
      assert_predicate repaired, :valid_encoding?
    end

    def deep_value_contains?(value, expected)
      return true if value == expected
      return value.any? { deep_value_contains?(it, expected) } if value.is_a?(Array)
      return value.any? { |_, item| deep_value_contains?(item, expected) } if value.is_a?(Hash)

      false
    end

    def invalid_utf8_string
      (+"token \xFF").tap { it.force_encoding(Encoding::UTF_8) }
    end
  end
end
