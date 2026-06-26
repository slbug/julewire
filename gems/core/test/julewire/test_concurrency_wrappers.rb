# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestConcurrencyWrappers < Minitest::Test
    class QueueingOutput
      def initialize
        @records = Queue.new
      end

      def write(value)
        @records << value
      end

      def pop(timeout: 1)
        @records.pop(timeout: timeout)
      end
    end

    def test_thread_wrapper_propagates_context_and_execution_overlay
      assert_wrapper_propagates_context_and_execution(worker: "thread") do |&block|
        Julewire.thread(&block).value
      end
    end

    def test_fiber_wrapper_propagates_context_and_execution_overlay
      assert_wrapper_propagates_context_and_execution(worker: "fiber") do |&block|
        Julewire.fiber(&block).resume
      end
    end

    def test_thread_and_fiber_wrappers_preserve_local_ruby_values
      Julewire.context.add(role: :admin)

      thread_role = Julewire.thread { Julewire.context[:role] }.value
      fiber_role = Julewire.fiber { Julewire.context[:role] }.resume

      assert_equal :admin, thread_role
      assert_equal :admin, fiber_role
    end

    def test_thread_and_fiber_wrappers_preserve_owned_truncation_metadata
      encoded = Julewire::Core::Propagation::Carrier.encode(envelope: { context: { blob: "x" * 20_000 } })
      contexts = Julewire::Core::Propagation::Carrier.restore({ "julewire" => encoded }) do
        [
          Julewire.thread { Julewire.context.to_h }.value,
          Julewire.fiber { Julewire.context.to_h }.resume
        ]
      end

      contexts.each { assert_truncated_context(it) }
    end

    def test_thread_wrapper_applies_propagated_execution_to_direct_emits
      output = QueueingOutput.new
      Julewire.configure { configure_destination(it, output: output) }

      Julewire.with_execution(type: :request, fields: { trace_id: "trace-1" }, emit_summary: false) do
        Julewire.thread { Julewire.emit(message: "direct") }.join
      end

      record = JSON.parse(output.pop)

      assert_equal "trace-1", record.dig("execution", "trace_id")
      assert_equal "request", record.dig("execution", "type")
    end

    def test_wrappers_require_blocks
      assert_raises(ArgumentError) { Julewire.thread }
      assert_raises(ArgumentError) { Julewire.fiber }
    end

    private

    def assert_wrapper_propagates_context_and_execution(worker:, &run)
      context, carry, execution = capture_wrapper_state(worker: worker, run: run)

      assert_equal "request-1", context[:request_id]
      assert_equal worker, context[:worker]
      assert_equal "trace-1", carry.dig(:http, :request_headers, :traceparent)
      assert_equal worker, carry[:worker]
      assert_equal "trace-1", execution[:trace_id]
      assert_equal "worker", execution[:type]
      assert_empty Julewire.context.to_h
    end

    def capture_wrapper_state(worker:, run:)
      Julewire.with_execution(type: :request, fields: { trace_id: "trace-1" }, emit_summary: false) do
        Julewire.context.add(request_id: "request-1")
        Julewire.carry.add(http: { request_headers: { traceparent: "trace-1" } })
        run.call { capture_nested_wrapper_state(worker) }
      end
    end

    def capture_nested_wrapper_state(worker)
      Julewire.context.add(worker: worker)
      Julewire.carry.add(worker: worker)
      Julewire.with_execution(type: :worker, emit_summary: false) do
        [Julewire.context.to_h, Julewire.carry.to_h, Julewire.current_execution.execution_hash]
      end
    end

    def assert_truncated_context(context)
      assert_match(/\Ax+\.\.\.\[Truncated\]\z/, context.fetch(:blob))
      assert_symbol_truncation_metadata context.fetch(:_julewire_truncation),
                                        fields: ["blob"],
                                        max_string_bytes: Julewire::Core::Serialization::Serializer::DEFAULT_MAX_STRING_BYTES
    end
  end
end
