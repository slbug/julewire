# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestEmitInput < Minitest::Test
    cover "Julewire::Core.emit_input"
    cover Julewire::Core::Records::LazyEmitInput
    cover Julewire::Core::Records::RawInput
    cover "Julewire::Core::Records::LazyEmitInput.empty_input?"
    cover "Julewire::Core::Records::LazyEmitInput.input_hash"
    cover "Julewire::Core::Records::BuildInput*"
    cover "Julewire::Core::Processing::Pipeline#build_draft"
    cover "Julewire::Core::Processing::Pipeline#emit"
    cover "Julewire::Core::Processing::Pipeline#emit_input_with_guard"
    cover "Julewire::Core::Processing::Pipeline#emit_with_level_check"
    cover "Julewire::Core::FacadeMethods#emit"
    cover "Julewire::Core::Runtime#emit"
    cover "Julewire::Core::Runtime#emit_without_level"
    cover "Julewire::Core::Runtime#emit_with_level_check"

    class PayloadHash < Hash; end

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

    def test_runtime_emit_keyword_only_input_does_not_create_empty_message
      records = configure_record_capture

      Julewire.runtime.emit(event: "runtime.event")

      record = records.fetch(0)

      assert_equal "runtime.event", record.fetch(:event)
      assert_nil record.fetch(:message)
    end

    def test_runtime_emit_without_level_keyword_only_input_does_not_create_nil_message
      records = configure_record_capture(level: :fatal)

      Core::RuntimeLocator.current.emit_without_level(event: "debug.event", severity: :debug)

      record = records.fetch(0)

      assert_nil record.fetch(:message)
      assert_equal "debug.event", record.fetch(:event)
    end

    def test_runtime_emit_without_level_preserves_positional_record
      records = configure_record_capture(level: :fatal)

      Core::RuntimeLocator.current.emit_without_level("debug message", event: "debug.event", severity: :debug)

      record = records.fetch(0)

      assert_equal "debug message", record.fetch(:message)
      assert_equal "debug.event", record.fetch(:event)
    end

    def test_runtime_emit_without_level_forwards_lazy_blocks
      records = configure_record_capture(level: :fatal)
      called = false

      Core::RuntimeLocator.current.emit_without_level(event: "debug.event") do
        called = true
        { message: "lazy debug", severity: :debug }
      end

      record = records.fetch(0)

      assert_true called
      assert_equal "lazy debug", record.fetch(:message)
      assert_equal "debug.event", record.fetch(:event)
      assert_equal :debug, record.fetch(:severity)
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

    def test_explicit_scalar_payload_is_wrapped_when_unknown_fields_are_present
      records = configure_record_capture

      Julewire.emit(message: "saved", payload: "raw", attempt: 2)

      assert_equal({ value: "raw", attempt: 2 }, records.fetch(0).fetch(:payload))
    end

    def test_explicit_payload_hash_subclass_merges_unknown_fields_as_hash
      records = configure_record_capture
      payload = PayloadHash[attempt: 1]

      Julewire.emit(message: "saved", payload: payload, account_id: "acct-1")

      assert_equal({ attempt: 1, account_id: "acct-1" }, records.fetch(0).fetch(:payload))
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

      assert_false called
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
      assert_true record.dig(:payload, :built)
    end

    def test_emit_lazy_block_can_supply_severity_when_eager_input_has_none
      records = configure_record_capture(level: :error)
      called = false

      Julewire.emit do
        called = true
        { severity: :fatal, message: "boom" }
      end

      assert_true called
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
      input = Core::Records::LazyEmitInput.with_severity(
        :warn,
        { "message" => "lazy message", "custom" => "value", severity: :fatal }
      )
      scalar_input = Core::Records::LazyEmitInput.with_severity(:info, "scalar message")

      refute_kind_of Hash, input
      assert_true input.key?(:severity)
      assert_true input.key?("severity")
      assert_true input.key?(:message)
      assert_true input.key?("message")
      assert_true input.key?(:custom)
      assert_false input.key?(:missing)
      assert_false input.key?(nil)
      assert_equal :warn, Core::Records::RawInput.value(input, :severity)
      assert_equal "lazy message", input[:message]
      assert_equal "value", input[:custom]
      assert_equal(
        [["message", "lazy message"], ["custom", "value"], %i[severity warn]],
        input.each.to_a
      )
      assert_equal({ "message" => "lazy message", "custom" => "value", severity: :warn }, input.to_h)
      assert_true scalar_input.key?(:message)
      assert_false scalar_input.key?(:missing)
      assert_equal([[:message, "scalar message"], %i[severity info]], scalar_input.each.to_a)
      assert_equal :fallback, Core::Records::RawInput.value("scalar", :message, default: :fallback)
    end

    def test_lazy_severity_input_uses_to_s_for_scalar_messages
      scalar = Object.new
      scalar.define_singleton_method(:to_s) { "object message" }
      input = Core::Records::LazyEmitInput.with_severity(:info, scalar)

      assert_equal "object message", input[:message]
      assert_equal([[:message, "object message"], %i[severity info]], input.each.to_a)
    end

    def test_lazy_severity_input_treats_hash_subclasses_as_hashes
      input = Core::Records::LazyEmitInput.with_severity(
        :warn,
        PayloadHash[message: "lazy message", custom: "value"]
      )

      assert_equal "lazy message", input[:message]
      assert_equal "value", input[:custom]
      assert_equal({ message: "lazy message", custom: "value", severity: :warn }, input.to_h)
    end

    def test_lazy_emit_input_direct_merge_edges
      base = { message: "base" }

      assert_same base, Core::Records::LazyEmitInput.call(base) { nil }
      assert_equal({ message: "lazy" }, Core::Records::LazyEmitInput.call({ message: "base" }) { { message: "lazy" } })
      assert_equal({ message: "lazy" }, Core::Records::LazyEmitInput.call("base") { "lazy" })
    end

    def test_lazy_emit_input_uses_to_s_for_scalar_messages
      input = Object.new
      input.define_singleton_method(:to_s) { "object message" }

      assert_equal({ event: "lazy", message: "object message" },
                   Core::Records::LazyEmitInput.call({ event: "lazy" }) { input })
    end

    def test_lazy_emit_input_treats_hash_subclasses_as_hashes
      lazy = PayloadHash[message: "lazy", payload: { lazy: true }]

      result = Core::Records::LazyEmitInput.call({ event: "base" }) { lazy }

      assert_equal({ event: "base", message: "lazy", payload: { lazy: true } }, result)
    end

    def test_lazy_emit_input_preserves_lazy_severity_when_eager_input_has_no_explicit_severity
      result = Core::Records::LazyEmitInput.call({ message: "base" }) { { severity: :warn, payload: { lazy: true } } }

      assert_equal({ message: "base", severity: :warn, payload: { lazy: true } }, result)
    end

    def test_lazy_emit_input_merges_lazy_severity_wrapper
      lazy = Core::Records::LazyEmitInput.with_severity(:warn, { message: "lazy", payload: { lazy: true } })

      result = Core::Records::LazyEmitInput.call({ event: "base" }) { lazy }

      assert_equal({ event: "base", message: "lazy", payload: { lazy: true }, severity: :warn }, result)
    end

    def test_lazy_emit_input_keeps_eager_explicit_severity_over_lazy_severity
      result = Core::Records::LazyEmitInput.call({ severity: :error, message: "base" }) do
        { severity: :debug, payload: { lazy: true } }
      end

      assert_equal({ severity: :error, message: "base", payload: { lazy: true } }, result)
    end

    def test_raw_input_value_prefers_symbol_keys_and_uses_string_fallback
      input = { message: "symbol", "message" => "string" }

      assert_equal "symbol", Core::Records::RawInput.value(input, :message)
      assert_equal "string", Core::Records::RawInput.value({ "message" => "string" }, :message)
      assert_equal :fallback, Core::Records::RawInput.value({ other: "value" }, :message, default: :fallback)
    end

    def test_raw_input_treats_hash_subclasses_as_hash_inputs
      input = PayloadHash[message: "subclass", severity: :warn]

      assert_true Core::Records::RawInput.explicit_severity?(input)
      assert_equal "subclass", Core::Records::RawInput.value(input, :message)
    end

    def test_lazy_emit_input_replaces_empty_eager_input
      lazy_input = { message: "lazy" }
      empty_subclass = PayloadHash.new

      assert_same lazy_input, Core::Records::LazyEmitInput.call(nil) { lazy_input }
      assert_same lazy_input, Core::Records::LazyEmitInput.call({}) { lazy_input }
      assert_same lazy_input, Core::Records::LazyEmitInput.call(empty_subclass) { lazy_input }
    end

    def test_lazy_emit_input_treats_empty_string_as_eager_message
      result = Core::Records::LazyEmitInput.call("") { { payload: { lazy: true } } }

      assert_equal({ message: "", payload: { lazy: true } }, result)
    end

    def test_core_emit_input_direct_merge_edges
      fields = { event: "direct" }
      input = { message: "base" }
      hash_subclass = Class.new(Hash).new.merge!(message: "subclass")
      scalar = Object.new.tap { it.define_singleton_method(:to_s) { "scalar" } }

      assert_same fields, Core.emit_input(Core::UNSET, fields)
      assert_equal({ message: "base", event: "direct" }, Core.emit_input(input, fields))
      assert_equal({ message: "subclass", event: "direct" }, Core.emit_input(hash_subclass, fields))
      assert_equal({ message: "scalar", event: "direct" }, Core.emit_input(scalar, fields))
      assert_equal "unchanged", Core.emit_input("unchanged", {})
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
          output: Julewire::Testing::NullOutput.new
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
