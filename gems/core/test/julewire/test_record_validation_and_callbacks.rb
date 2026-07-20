# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestRecordValidationAndCallbacks < Minitest::Test
    cover Julewire::Core::Records::Record
    cover Julewire::Core::Diagnostics::CallbackNotifier
    class FailingOutput
      def write(_value)
        raise "write failed"
      end
    end

    def test_record_rejects_unknown_kind
      error = assert_raises(ArgumentError) do
        build_record({ kind: :unknown }, context: {}, scope: nil)
      end

      assert_equal "unsupported record kind: :unknown", error.message
    end

    def test_emit_contains_unknown_kind_without_crashing_application
      output = StringIO.new

      Julewire.configure { configure_destination(it, output: output) }

      assert_nil Julewire.emit(kind: :unknown, message: "bad adapter")

      record = JSON.parse(output.string)

      assert_equal "julewire.emit_error", record.fetch("event")
      assert_equal "ArgumentError", record.dig("payload", "error", "class")
    end

    def test_emit_error_record_bypasses_application_level
      output = StringIO.new

      Julewire.configure do |config|
        config.level = :fatal
        configure_destination(config, output: output)
      end

      assert_nil Julewire.emit(kind: :unknown, severity: :fatal, message: "bad adapter")

      record = JSON.parse(output.string)

      assert_equal "julewire.emit_error", record.fetch("event")
      assert_equal "error", record.fetch("severity")
      assert_equal "ArgumentError", record.dig("payload", "error", "class")
    end

    def test_record_preserves_falsey_explicit_event_and_timestamp_values
      record = build_record(
        {
          event: false,
          severity: :info,
          timestamp: false
        },
        context: {},
        scope: nil
      )

      assert_equal "false", record.fetch(:event)
      assert_false record.fetch(:timestamp)
    end

    def test_record_with_log_safe_fields_is_ractor_shareable
      record = build_record(
        {
          message: "shareable",
          payload: { count: 1, ids: %w[a b] },
          attributes: { app: { region: "eu" } }
        },
        context: { request_id: "r-1" },
        scope: nil
      )

      assert_true Ractor.shareable?(record)
    end

    def test_failure_notifier_passes_metadata_hash
      calls = Queue.new

      Julewire.configure do |config|
        configure_destination(config, output: FailingOutput.new)
        config.on_failure = lambda do |error, metadata|
          calls << [error.class.name, metadata.fetch(:phase), metadata.fetch(:record_metadata)]
        end
      end

      Julewire.emit(source: "app", event: "failed")

      error_class, phase, metadata = safe_queue_pop(calls)

      assert_equal "RuntimeError", error_class
      assert_equal :output, phase
      assert_equal "app", metadata.fetch(:source)
      assert_equal "failed", metadata.fetch(:event)
    end

    def test_callback_signature_errors_are_counted_when_invoked
      Julewire.configure do |config|
        configure_destination(config, output: FailingOutput.new)
        config.on_failure = lambda do |_error, _metadata, required:|
          required
        end
      end

      Julewire.emit(source: "app", event: "failed")

      assert_equal 1, destination_health.dig(:counts, :callback_error)
    end

    def test_failure_notifier_allows_optional_callback_keywords
      calls = Queue.new

      Julewire.configure do |config|
        configure_destination(config, output: FailingOutput.new)
        config.on_failure = lambda do |_error, _metadata, optional: :default|
          calls << optional
        end
      end

      Julewire.emit("failed")

      assert_equal :default, safe_queue_pop(calls)
    end

    def test_callback_notifier_calls_fixed_metadata_shape
      callback = CountingCallback.new

      2.times { Julewire::Core::Diagnostics::CallbackNotifier.call(callback, RuntimeError.new("boom"), { phase: :output }) }

      assert_equal 0, callback.parameter_calls
      assert_equal [[:output], [:output]], callback.calls
    end

    def test_callback_notifier_returns_true_and_restores_existing_fiber_state
      key = Julewire::Core::Diagnostics::CallbackNotifier.const_get(:ACTIVE_KEY)
      Fiber[key] = :outer

      result = Julewire::Core::Diagnostics::CallbackNotifier.call(
        ->(_error, _metadata) {},
        RuntimeError.new("boom"),
        { phase: :output }
      )

      assert_true result
      assert_equal :outer, Fiber[key]
    ensure
      Fiber[key] = nil if key
    end

    def test_callback_notifier_reports_nested_callback_with_original_metadata
      nested_result = nil

      result = Julewire::Core::Diagnostics::CallbackNotifier.call(
        lambda do |_error, metadata|
          nested_result = Julewire::Core::Diagnostics::CallbackNotifier.call(
            ->(_nested_error, _nested_metadata) { flunk "nested callback should not run" },
            RuntimeError.new("nested"),
            metadata
          )
        end,
        RuntimeError.new("outer"),
        { destination: :default, phase: :drop }
      )

      assert_true result
      assert_true Julewire::Core::Diagnostics::CallbackNotifier.failure?(nested_result)
      assert_equal :drop, nested_result.to_h.fetch(:phase)
      assert_equal :default, nested_result.to_h.fetch(:destination)
    end

    def test_callback_recursion_is_suppressed_and_counted
      Julewire.configure do |config|
        configure_destination(config, output: FailingOutput.new)
        config.on_drop = ->(_reason, _metadata) { Julewire.emit("nested") }
      end

      Julewire.emit("outer")

      assert_equal 1, Julewire.health.dig(:pipeline, :destinations, :default, :counts, :callback_error)
    end

    class CountingCallback
      attr_reader :calls, :parameter_calls

      def initialize
        @calls = []
        @parameter_calls = 0
      end

      def parameters
        @parameter_calls += 1
        [%i[req error], %i[key phase]]
      end

      def call(_error, metadata)
        @calls << [metadata.fetch(:phase)]
      end
    end
  end
end
