# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestConcurrencyWrappers < Minitest::Test
    cover "Julewire::Core::ContextStore#merged_execution_hash"
    cover "Julewire::Core::ContextStore#with_propagation"
    cover "Julewire.thread"
    cover "Julewire.fiber"
    cover "Julewire::Core::FacadeMethods#fiber"
    cover "Julewire::Core::FacadeMethods#thread"
    cover Julewire::Core::Propagation::Carrier
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
        safe_thread_value(safe_julewire_thread(&block))
      end
    end

    def test_fiber_wrapper_propagates_context_and_execution_overlay
      assert_wrapper_propagates_context_and_execution(worker: "fiber") do |&block|
        Julewire.fiber(&block).resume
      end
    end

    def test_thread_and_fiber_wrappers_preserve_local_ruby_values
      Julewire.context.add(role: :admin)

      thread_role = safe_thread_value(safe_julewire_thread { Julewire.context[:role] })
      fiber_role = Julewire.fiber { Julewire.context[:role] }.resume

      assert_equal :admin, thread_role
      assert_equal :admin, fiber_role
    end

    def test_thread_and_fiber_wrappers_preserve_owned_truncation_metadata
      encoded = Julewire::Core::Propagation::Carrier.encode(envelope: { context: { blob: "x" * 20_000 } })
      contexts = Julewire::Core::Propagation::Carrier.restore({ "julewire" => encoded }) do
        [
          safe_thread_value(safe_julewire_thread { Julewire.context.to_h }),
          Julewire.fiber { Julewire.context.to_h }.resume
        ]
      end

      contexts.each { assert_truncated_context(it) }
    end

    def test_thread_wrapper_applies_propagated_execution_to_direct_emits
      output = QueueingOutput.new
      Julewire.configure { configure_destination(it, output: output) }

      Julewire.with_execution(type: :request, fields: { trace_id: "trace-1" }, emit_summary: false) do
        safe_thread_value(safe_julewire_thread { Julewire.emit(message: "direct") })
      end

      record = JSON.parse(safe_queue_pop(output))

      assert_equal "trace-1", record.dig("execution", "trace_id")
      assert_equal "request", record.dig("execution", "type")
    end

    def test_thread_and_fiber_wrappers_forward_resume_and_thread_arguments
      thread_value = safe_thread_value(Julewire.thread(:left, :right) { |left, right| [left, right] })
      fiber_value = Julewire.fiber { |left, right| [left, right] }.resume(:left, :right)
      single_thread_value = safe_thread_value(Julewire.thread(:left, :right) { |first| first })
      single_fiber_value = Julewire.fiber { |first| first }.resume(:left, :right)

      assert_equal %i[left right], thread_value
      assert_equal %i[left right], fiber_value
      assert_equal :left, single_thread_value
      assert_equal :left, single_fiber_value
    end

    def test_fiber_wrapper_forwards_fiber_keywords
      assert_true Julewire.fiber(blocking: true) { Fiber.current.blocking? }.resume
    end

    def test_wrapper_guard_is_cleared_inside_block_and_restored_after_failure
      facade = Object.new.extend(Core::FacadeMethods)
      key = Core::Runtime::CONFIGURE_GUARD_KEY
      Fiber[key] = :guarded

      error = assert_raises(RuntimeError) do
        facade.__send__(:with_cleared_configure_guard) do
          assert_nil Fiber[key]
          raise "boom"
        end
      end

      assert_equal "boom", error.message
      assert_equal :guarded, Fiber[key]
    ensure
      Fiber[key] = nil if defined?(key)
    end

    def test_thread_and_fiber_wrappers_clear_inherited_configure_guard
      key = Core::Runtime::CONFIGURE_GUARD_KEY
      Fiber[key] = :guarded

      thread_value = safe_thread_value(Julewire.thread { Fiber[key] })
      fiber_value = Julewire.fiber { Fiber[key] }.resume

      assert_nil thread_value
      assert_nil fiber_value
      assert_equal :guarded, Fiber[key]
    ensure
      Fiber[key] = nil if defined?(key)
    end

    def test_wrappers_require_blocks
      unexpected_thread = nil
      assert_raises_message(ArgumentError, "block required") { unexpected_thread = Julewire.thread }
      assert_raises_message(ArgumentError, "block required") { Julewire.fiber }
    ensure
      cleanup_thread(unexpected_thread)
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
