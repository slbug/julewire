# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestEnvelopePayload < Minitest::Test
    cover "Julewire::Core::Runtime#emit_envelope"
    cover "Julewire::Core::Runtime#envelope_draft"
    cover "Julewire::Core::Runtime#envelope_hash"
    cover Julewire::Core::Records::Formatter
    def test_emit_envelope_writes_through_active_runtime
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      captured = []
      configure_runtime_capture(runtime, output, captured)
      emit_sample_envelope(runtime)

      record = JSON.parse(output.string)

      assert_equal "done", record.fetch("message")
      assert_equal "r1", record.dig("context", "request_id")
      assert_equal "job", record.dig("execution", "type")
      assert_equal "t1", record.dig("execution", "trace_id")
      assert_equal "u1", captured.first.dig(:attributes, :user_id)
      assert_equal "node-a", captured.first.dig(:neutral, :worker, :node)
      assert_equal "trace-1", captured.first.dig(:carry, :http, :request_headers, :traceparent)
      assert_false record.key?("carry")
      assert_equal "ractor", record.dig("labels", "worker")
    end

    def test_emit_envelope_drops_after_runtime_close
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      runtime.configure { configure_destination(it, output: output) }
      runtime.close(timeout: 1)

      runtime.emit_envelope(
        input: { message: "after" },
        context: {},
        attributes: {},
        neutral: {},
        carry: {},
        scope: empty_scope
      )

      assert_empty output.string
      assert_equal 1, runtime.health.dig(:counts, :post_close_emits)
    end

    def test_emit_envelope_can_bypass_runtime_level
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      runtime.configure do |config|
        config.level = :fatal
        configure_destination(config, output: output)
      end

      runtime.emit_envelope(
        input: { severity: :debug, message: "debug" },
        context: {},
        attributes: {},
        neutral: {},
        carry: {},
        scope: empty_scope,
        enforce_level: false
      )

      assert_equal "debug", JSON.parse(output.string).fetch("message")
    end

    def test_emit_envelope_enforces_runtime_level_by_default
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      runtime.configure do |config|
        config.level = :fatal
        configure_destination(config, output: output)
      end

      runtime.emit_envelope(
        input: { severity: :debug, message: "debug" },
        context: {},
        attributes: {},
        neutral: {},
        carry: {},
        scope: empty_scope
      )

      assert_empty output.string
      assert_equal 1, runtime.health.dig(:pipeline, :counts, :level_dropped)
    end

    def test_emit_envelope_defaults_to_unowned_input
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      failures = configure_runtime_failure_capture(runtime, output: output)

      runtime.emit_envelope(
        input: { message: "reserved" },
        context: { _julewire_truncation: fixture_truncation_metadata },
        attributes: {},
        neutral: {},
        carry: {},
        scope: empty_scope
      )

      error, metadata = failures.pop(timeout: 1)

      assert_empty output.string
      assert_instance_of ArgumentError, error
      assert_equal :emit_envelope, metadata.fetch(:action)
    end

    def test_emit_envelope_accepts_owned_truncation_metadata
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      captured = []
      configure_runtime_capture(runtime, output, captured)

      runtime.emit_envelope(
        input: { message: "owned", event: "work" },
        context: { ids: [1], _julewire_truncation: fixture_truncation_metadata },
        attributes: { plan: "gold" },
        neutral: { worker: { node: "owned-node" } },
        carry: { trace: { id: "owned-trace" } },
        scope: Julewire::Core::Execution::ScopeSnapshot.new(
          execution: { type: "owned-job", trace_id: "owned-exec" },
          labels: { worker: "owned-ractor" }
        ),
        owned: true
      )

      record = JSON.parse(output.string)

      assert_equal "owned", record.fetch("message")
      metadata = record.dig("context", "_julewire_truncation")

      assert_equal ["ids"], metadata.fetch("truncated_fields")
      assert_equal 10, metadata.dig("limits", "max_string_bytes")
      assert_equal "gold", record.dig("attributes", "plan")
      assert_equal "owned-job", record.dig("execution", "type")
      assert_equal "owned-ractor", record.dig("labels", "worker")
      assert_equal "owned-node", captured.first.dig(:neutral, :worker, :node)
      assert_equal "owned-trace", captured.first.dig(:carry, :trace, :id)
    end

    def test_emit_envelope_accepts_owned_input_truncation_metadata
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      configure_runtime_capture(runtime, output, [])

      runtime.emit_envelope(
        input: {
          message: "owned-input",
          payload: { ids: [1], _julewire_truncation: fixture_truncation_metadata }
        },
        context: {},
        attributes: {},
        neutral: {},
        carry: {},
        scope: empty_scope,
        owned: true
      )

      metadata = JSON.parse(output.string).dig("payload", "_julewire_truncation")

      assert_equal ["ids"], metadata.fetch("truncated_fields")
      assert_equal 10, metadata.dig("limits", "max_string_bytes")
    end

    def test_emit_envelope_ignores_non_hash_sections
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      captured = []
      configure_runtime_capture(runtime, output, captured)

      runtime.emit_envelope(
        input: { message: "coerced", event: "work" },
        context: "context",
        attributes: "attributes",
        neutral: "neutral",
        carry: "carry",
        scope: empty_scope
      )

      record = JSON.parse(output.string)

      assert_equal "coerced", record.fetch("message")
      assert_equal({}, captured.first.fetch(:context))
      assert_equal({}, captured.first.fetch(:attributes))
      assert_equal({}, captured.first.fetch(:neutral))
      assert_equal({}, captured.first.fetch(:carry))
      assert_false record.key?("context")
      assert_false record.key?("attributes")
      assert_false record.key?("neutral")
    end

    def test_emit_envelope_accepts_hash_subclass_sections
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      captured = []
      context = Class.new(Hash).new
      context[:request_id] = "request-1"
      configure_runtime_capture(runtime, output, captured)

      runtime.emit_envelope(
        input: { message: "hash-subclass", event: "work" },
        context: context,
        attributes: {},
        neutral: {},
        carry: {},
        scope: empty_scope
      )

      assert_equal "request-1", captured.first.dig(:context, :request_id)
      assert_equal "request-1", JSON.parse(output.string).dig("context", "request_id")
    end

    def test_emit_envelope_contains_and_reports_non_hash_owned_sections
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      failures = configure_runtime_failure_capture(runtime, output: output)

      result = runtime.emit_envelope(
        input: { message: "owned-coerced", event: "work" },
        context: "context",
        attributes: "attributes",
        neutral: "neutral",
        carry: "carry",
        scope: empty_scope,
        owned: true
      )

      error, metadata = failures.pop(timeout: 1)

      assert_nil result
      assert_empty output.string
      assert_instance_of TypeError, error
      assert_equal "record context must be a Hash", error.message
      assert_equal :emit_envelope, metadata.fetch(:action)
    end

    def test_emit_envelope_keeps_each_owned_section_strict
      %i[context attributes neutral carry].each do |section|
        runtime = Julewire::Core::Runtime.new
        output = StringIO.new
        failures = configure_runtime_failure_capture(runtime, output: output)
        sections = { context: {}, attributes: {}, neutral: {}, carry: {} }
        sections[section] = "not-a-hash"

        result = runtime.emit_envelope(
          input: { message: "strict-#{section}", event: "work" },
          scope: empty_scope,
          owned: true,
          **sections
        )
        error, metadata = failures.pop(timeout: 1)

        assert_nil result, section
        assert_empty output.string, section
        assert_instance_of TypeError, error, section
        assert_equal "record #{section} must be a Hash", error.message, section
        assert_equal :emit_envelope, metadata.fetch(:action), section
      ensure
        runtime&.close
      end
    end

    def test_emit_envelope_honors_error_backtrace_limit
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      captured = []
      runtime.configure do |config|
        config.error_backtrace_lines = 0
        configure_destination(config, formatter: capture_formatter(captured), output: output)
      end

      runtime.emit_envelope(
        input: { message: "plain", error: raised_error }, context: {}, attributes: {}, neutral: {}, carry: {},
        scope: empty_scope
      )
      runtime.emit_envelope(
        input: { message: "owned", error: raised_error }, context: {}, attributes: {}, neutral: {}, carry: {},
        scope: empty_scope, owned: true
      )

      assert_equal(%w[plain owned], output.string.lines.map { JSON.parse(it).fetch("message") })
      assert_false captured.fetch(0).fetch(:error).key?(:backtrace)
      assert_false captured.fetch(1).fetch(:error).key?(:backtrace)
    end

    def test_emit_envelope_reports_invalid_severity
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      runtime.configure { configure_destination(it, output: output) }

      capture_io do
        runtime.emit_envelope(
          input: { severity: false, message: "plain" }, context: {}, attributes: {}, neutral: {}, carry: {},
          scope: empty_scope
        )
        runtime.emit_envelope(
          input: { severity: false, message: "owned" }, context: {}, attributes: {}, neutral: {}, carry: {},
          scope: empty_scope, owned: true
        )
      end

      assert_equal(%w[plain owned], output.string.lines.map { JSON.parse(it).fetch("message") })
      assert_equal 2, runtime.health.fetch(:counts).fetch(:invalid_record_severities)
    end

    def test_emit_envelope_rejects_calls_inside_configure
      runtime = Julewire::Core::Runtime.new

      error = assert_raises(Julewire::Error) do
        runtime.configure do |config|
          configure_destination(config, output: StringIO.new)
          runtime.emit_envelope(
            input: { message: "bad" }, context: {}, attributes: {}, neutral: {}, carry: {}, scope: empty_scope
          )
        end
      end

      assert_equal "Julewire.emit_envelope cannot be called from inside Julewire.configure", error.message
    end

    def test_emit_envelope_failures_use_runtime_failure_callback
      runtime = Julewire::Core::Runtime.new
      failures = configure_runtime_failure_capture(runtime)
      pipeline = runtime.__send__(:runtime_state).pipeline
      previous_counts = runtime.health.fetch(:counts)

      with_overridden_singleton_method(pipeline, :emit_record, proc { |_record, **| raise "envelope failed" }) do
        assert_nil runtime.emit_envelope(
          input: { message: "lost" }, context: {}, attributes: {}, neutral: {}, carry: {}, scope: empty_scope
        )
      end

      error, metadata = failures.pop(timeout: 1)
      health = runtime.health

      assert_equal "envelope failed", error.message
      assert_equal :runtime, metadata.fetch(:phase)
      assert_equal :emit_envelope, metadata.fetch(:action)
      assert_equal 1, health.dig(:counts, :runtime_failures) - previous_counts.fetch(:runtime_failures)
    end

    private

    def configure_runtime_capture(runtime, output, captured)
      runtime.configure do |config|
        configure_destination(config, formatter: capture_formatter(captured), output: output)
      end
    end

    def capture_formatter(captured)
      lambda do |record|
        captured << Julewire::Core::Fields::FieldSet.deep_dup(record)
        Julewire::Core::Records::Formatter.new.call(record)
      end
    end

    def emit_sample_envelope(runtime)
      runtime.emit_envelope(
        input: { "message" => "done", "source" => "app", "event" => "work" },
        context: { "request_id" => "r1" },
        attributes: { "user_id" => "u1" },
        neutral: { "worker" => { "node" => "node-a" } },
        carry: { "http" => { "request_headers" => { "traceparent" => "trace-1" } } },
        scope: Julewire::Core::Execution::ScopeSnapshot.new(
          execution: { type: "job", trace_id: "t1" },
          labels: { worker: "ractor" }
        ),
        owned: false
      )
    end

    def empty_scope
      Julewire::Core::Execution::ScopeSnapshot.new
    end

    def raised_error
      raise "boom"
    rescue RuntimeError => e
      e
    end
  end
end
