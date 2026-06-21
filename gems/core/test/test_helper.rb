# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "julewire/core/testing/coverage"
Julewire::Core::Testing::Coverage.start!

require "julewire/core"
require "julewire/core/testing"
require_relative "support/julewire/core/test_helpers"
require_relative "support/julewire/core/test_payload_processor"

require "minitest/autorun"
require "mutant/minitest/coverage"

module Minitest
  class Test
    include Julewire::Core::TestHelpers

    TEST_THREAD_TIMEOUT = 1

    def setup
      reset_julewire!
    end

    def assert_registry_rejects_object(registry, message)
      error = assert_raises(ArgumentError) do
        registry.use Object.new
      end

      assert_match message, error.message
    end

    def assert_raises_message(error_class, message, &)
      error = assert_raises(error_class, &)

      assert_match message, error.message
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

    def nonblocking_queue_values(queue) = Julewire::Core::Testing.nonblocking_queue_values(queue)

    def destination_health(name = :default)
      Julewire.health.fetch(:pipeline).fetch(:destinations).fetch(name)
    end

    def build_destination(output:, encoder: Julewire::Core::Serialization::JsonEncoder.new,
                          formatter: Julewire::Core::Records::Formatter.new, name: :default,
                          on_drop: nil, on_failure: nil, max_record_bytes: Julewire::Core::DEFAULT_MAX_RECORD_BYTES)
      Julewire::Core::Destinations::Destination.new(
        name: name,
        close_output: false,
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

    def cleanup_thread(thread, timeout: TEST_THREAD_TIMEOUT)
      return unless thread
      return if thread_joined?(thread, timeout: timeout)

      thread.kill
      thread.join
    end

    def thread_joined?(thread, timeout: TEST_THREAD_TIMEOUT)
      return true if thread.join(0)
      return true if thread.join(timeout)

      false
    end

    def with_overridden_singleton_method(receiver, method_name, replacement, &)
      Julewire::Core::Testing.with_overridden_singleton_method(receiver, method_name, replacement, &)
    end

    def assert_invalid_utf8_repaired
      repaired = yield invalid_utf8_string

      assert_equal "token ?", repaired
      assert_predicate repaired, :valid_encoding?
    end

    def invalid_utf8_string
      (+"token \xFF").tap { it.force_encoding(Encoding::UTF_8) }
    end
  end
end
