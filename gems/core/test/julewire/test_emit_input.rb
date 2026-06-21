# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestEmitInput < Minitest::Test
    def test_emit_accepts_string_message_shorthand
      result = nil
      records = capture_julewire_records do
        result = Julewire.emit("123")
      end

      record = records.fetch(0)

      assert_nil result
      assert_equal "123", record.fetch(:message)
      assert_equal "log", record.fetch(:event)
      assert_equal :info, record.fetch(:severity)
    end

    def test_emit_folds_scalar_with_keyword_fields_into_message_and_payload
      records = configure_record_capture(level: :debug)

      Julewire.warn("retrying", attempt: 3, event: "retry.scheduled")

      record = records.fetch(0)

      assert_equal :warn, record.fetch(:severity)
      assert_equal "retrying", record.fetch(:message)
      assert_equal "retry.scheduled", record.fetch(:event)
      assert_equal 3, record.dig(:payload, :attempt)
    end

    def test_emit_merges_unknown_keyword_fields_into_payload
      records = configure_record_capture

      Julewire.emit(message: "saved", payload: { id: 1 }, latency_ms: 12)

      record = records.fetch(0)

      assert_equal "saved", record.fetch(:message)
      assert_equal({ id: 1, latency_ms: 12 }, record.fetch(:payload))
    end

    def test_emit_preserves_internal_control_name_as_user_payload
      records = configure_record_capture

      Julewire.emit(message: "saved", enforce_level: "user-field")

      assert_equal({ enforce_level: "user-field" }, records.fetch(0).fetch(:payload))
    end

    def test_runtime_emit_without_level_bypasses_core_threshold
      records = configure_record_capture(level: :fatal)

      Core::RuntimeLocator.current.emit_without_level(message: "debug", severity: :debug)

      assert_equal "debug", records.fetch(0).fetch(:message)
    end

    def test_emit_merges_unknown_positional_hash_fields_into_payload
      records = configure_record_capture

      Julewire.emit({ message: "saved", attempt: 3 })

      record = records.fetch(0)

      assert_equal "saved", record.fetch(:message)
      assert_equal({ attempt: 3 }, record.fetch(:payload))
    end

    def test_emit_merges_keyword_fields_into_positional_hash_input
      records = configure_record_capture

      Julewire.emit({ message: "saved", payload: { attempt: 1 } }, attempt: 2, event: "saved")

      record = records.fetch(0)

      assert_equal "saved", record.fetch(:message)
      assert_equal "saved", record.fetch(:event)
      assert_equal({ attempt: 1 }, record.fetch(:payload))
    end

    def test_emit_merges_unknown_lazy_hash_fields_into_payload
      records = configure_record_capture(level: :debug)

      Julewire.emit(severity: :debug) { { message: "saved", attempt: 3 } }

      record = records.fetch(0)

      assert_equal :debug, record.fetch(:severity)
      assert_equal "saved", record.fetch(:message)
      assert_equal({ attempt: 3 }, record.fetch(:payload))
    end

    def test_explicit_payload_fields_win_over_unknown_keyword_payload_fields
      records = configure_record_capture

      Julewire.emit(message: "saved", payload: { "attempt" => 1 }, attempt: 2)

      record = records.fetch(0)

      assert_equal({ attempt: 1 }, record.fetch(:payload))
    end

    def test_emit_is_noop_when_output_is_not_configured
      assert_nil Julewire.emit("123")
    end

    def test_emit_string_message_shorthand_respects_implicit_info_threshold
      records = configure_record_capture(level: :warn)

      Julewire.emit("below threshold")

      assert_empty records
    end

    def test_emit_lazy_block_is_not_evaluated_below_threshold
      records = configure_record_capture(level: :warn)
      called = false

      Julewire.emit(severity: :debug) do
        called = true
        { message: "below threshold" }
      end

      refute called
      assert_empty records
    end

    def test_emit_lazy_block_merges_record_fields_after_threshold_precheck
      records = configure_record_capture(level: :debug)

      Julewire.emit(severity: :debug, event: "lazy.record") do
        { message: "built lazily", payload: { built: true } }
      end

      record = records.fetch(0)

      assert_equal :debug, record.fetch(:severity)
      assert_equal "lazy.record", record.fetch(:event)
      assert_equal "built lazily", record.fetch(:message)
      assert record.dig(:payload, :built)
    end

    def test_emit_lazy_block_can_supply_severity_when_eager_input_has_none
      records = configure_record_capture(level: :error)
      called = false

      Julewire.emit do
        called = true
        { severity: :fatal, message: "boom" }
      end

      assert called
      assert_equal "boom", records.fetch(0).fetch(:message)
      assert_equal :fatal, records.fetch(0).fetch(:severity)
    end

    def test_emit_lazy_block_without_eager_severity_is_evaluated_then_level_checked
      records = configure_record_capture(level: :error)
      call_count = 0

      Julewire.emit do
        call_count += 1
        { severity: :debug, message: "below threshold" }
      end

      assert_equal 1, call_count
      assert_empty records
    end

    def test_emit_lazy_block_cannot_override_eager_severity
      records = configure_record_capture(level: :debug)

      Julewire.emit(severity: :warn, event: "lazy.record") do
        { severity: :fatal, message: "kept eager severity" }
      end

      record = records.fetch(0)

      assert_equal :warn, record.fetch(:severity)
      assert_equal "kept eager severity", record.fetch(:message)
    end

    def test_emit_lazy_block_accepts_scalar_message_with_base_severity
      records = configure_record_capture(level: :debug)

      Julewire.emit(severity: :debug) { "lazy message" }

      assert_equal "lazy message", records.fetch(0).fetch(:message)
      assert_equal :debug, records.fetch(0).fetch(:severity)
    end

    def test_lazy_severity_input_is_internal_hash_like_input
      input = Core::Records::LazyEmitInput.with_severity(:warn, message: "lazy message", severity: :fatal)

      refute_kind_of Hash, input
      assert input.key?(:severity)
      assert_equal :warn, Core::Records::RawInput.value(input, :severity)
      assert_equal "lazy message", input[:message]
      assert_equal({ message: "lazy message", severity: :warn }, input.to_h)
    end

    def test_lazy_emit_input_direct_merge_edges
      base = { message: "base" }

      assert_same base, Core::Records::LazyEmitInput.call(base) { nil }
      assert_equal({ message: "lazy" }, Core::Records::LazyEmitInput.call({ message: "base" }) { { message: "lazy" } })
      assert_equal({ message: "lazy" }, Core::Records::LazyEmitInput.call("base") { "lazy" })
    end

    def test_emit_normalizes_string_keys_before_threshold
      records = configure_record_capture(level: :warn)

      Julewire.emit("severity" => "debug", "message" => "below threshold")
      Julewire.emit("severity" => "error", "message" => "above threshold")

      assert_equal(["above threshold"], records.map { it.fetch(:message) })
    end

    def test_processors_cannot_mutate_caller_message_string
      message = "caller"
      processor = lambda do |record|
        record[:message] = "#{record[:message]}-mutated"
        nil
      end
      records = configure_record_capture(processors: [processor])

      Julewire.emit(message: message)

      assert_equal "caller", message
      assert_equal "caller-mutated", records.fetch(0).fetch(:message)
    end

    def test_processors_cannot_mutate_context_store_values
      records = []

      Julewire.configure do |config|
        configure_destination(
          config,
          formatter: Julewire::Core::TestHelpers::RecordCaptureFormatter.new(records),
          output: Julewire::Core::TestHelpers::NullOutput.new
        )
        config.processors.use(lambda do |record|
          account = record.dig(:context, :account).merge(id: "mutated")
          record[:context][:account] = account
          nil
        end)
      end

      Julewire.context.add(account: { id: "acct-1" })
      Julewire.emit("context")

      assert_equal "mutated", records.fetch(0).dig(:context, :account, :id)
      assert_equal "acct-1", Julewire.context[:account][:id]
    end
  end
end
