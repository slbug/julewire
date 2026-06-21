# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestEnvelopePayload < Minitest::Test
    cover Julewire::Core::Fields::FieldSet

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
      assert_equal "trace-1", captured.first.dig(:carry, :http, :request_headers, :traceparent)
      refute record.key?("carry")
      assert_equal "ractor", record.dig("labels", "worker")
    end

    def test_emit_envelope_drops_after_runtime_close
      runtime = Julewire::Core::Runtime.new
      output = StringIO.new
      runtime.configure { configure_destination(it, output: output) }
      runtime.close(timeout: 1)

      runtime.emit_envelope(input: { message: "after" }, context: {}, scope: empty_scope)

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
        scope: empty_scope,
        enforce_level: false
      )

      assert_equal "debug", JSON.parse(output.string).fetch("message")
    end

    private

    def configure_runtime_capture(runtime, output, captured)
      formatter = lambda do |record|
        captured << Julewire::Core::Fields::FieldSet.deep_dup(record)
        Julewire::Core::Records::Formatter.new.call(record)
      end
      runtime.configure do |config|
        configure_destination(config, formatter: formatter, output: output)
      end
    end

    def emit_sample_envelope(runtime)
      runtime.emit_envelope(
        input: { "message" => "done", "source" => "app", "event" => "work" },
        context: { "request_id" => "r1" },
        carry: { "http" => { "request_headers" => { "traceparent" => "trace-1" } } },
        scope: Julewire::Core::Execution::ScopeSnapshot.new(
          execution: { type: "job", trace_id: "t1" },
          labels: { worker: "ractor" }
        )
      )
    end

    def empty_scope
      Julewire::Core::Execution::ScopeSnapshot.new
    end
  end
end
