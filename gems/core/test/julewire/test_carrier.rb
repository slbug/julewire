# frozen_string_literal: true

require "test_helper"
require "json"

module Julewire
  class TestCarrier < Minitest::Test
    cover "Julewire::Core::ContextStore#with_propagation"
    cover Julewire::Core::Propagation::Carrier
    cover "Julewire::Core::Propagation::Carrier.carrier_value"
    cover "Julewire::Core::Propagation::Carrier.restore"
    def test_inject_writes_serialized_propagation_envelope_to_flat_carrier
      carrier = nil

      Julewire.context.with(request_id: "request-1") do
        Julewire.carry.with(trace: { id: "trace-1" }) do
          carrier = Core::Propagation::Carrier.inject({})
        end
      end

      payload = JSON.parse(carrier.fetch("julewire"))

      assert_equal "request-1", payload.dig("context", "request_id")
      assert_equal "trace-1", payload.dig("carry", "trace", "id")
    end

    def test_extract_returns_symbol_key_envelope
      carrier = {
        "julewire" => JSON.generate(
          "context" => { "request_id" => "request-1" },
          "carry" => { "trace" => { "id" => "trace-1" } }
        )
      }

      envelope = Core::Propagation::Carrier.extract_envelope(carrier)

      assert_equal "request-1", envelope.dig(:context, :request_id)
      assert_equal "trace-1", envelope.dig(:carry, :trace, :id)
    end

    def test_extract_accepts_symbol_carrier_key
      carrier = {
        julewire: JSON.generate("context" => { "request_id" => "request-1" })
      }

      envelope = Core::Propagation::Carrier.extract_envelope(carrier)

      assert_equal "request-1", envelope.dig(:context, :request_id)
    end

    def test_extract_accepts_string_carrier_key_when_lookup_key_is_symbol
      carrier = {
        "x_julewire" => JSON.generate("context" => { "request_id" => "request-1" })
      }

      envelope = Core::Propagation::Carrier.extract_envelope(carrier, key: :x_julewire)

      assert_equal "request-1", envelope.dig(:context, :request_id)
    end

    def test_extract_returns_empty_for_missing_or_unsupported_carrier
      assert_empty Core::Propagation::Carrier.extract_envelope({})
      assert_empty Core::Propagation::Carrier.extract_envelope(Object.new)
    end

    def test_extract_result_reports_unsupported_carrier_as_missing_without_error
      result = Core::Propagation::Carrier.extract_result(Object.new)

      assert_equal :missing, result.status
      assert_nil result.reason
      assert_nil result.error
      assert_empty result.envelope
    end

    def test_extract_result_exposes_malformed_error_status_and_reason
      result = Core::Propagation::Carrier.extract_result({ "julewire" => "{" })

      assert_equal :malformed, result.status
      assert_equal "carrier payload is not valid JSON", result.reason
      assert_instance_of Core::Propagation::Carrier::ExtractionError, result.error
      assert_equal :malformed, result.error.status
      assert_equal "carrier payload is not valid JSON", result.error.reason
      assert_equal "carrier payload is not valid JSON", result.error.message
      assert_predicate result, :failure?
    end

    def test_extract_result_exposes_oversized_error_status_and_reason
      result = Core::Propagation::Carrier.extract_result({ "julewire" => "{}" }, max_bytes: 1)

      assert_equal :oversized, result.status
      assert_equal "carrier payload exceeds max_bytes", result.reason
      assert_instance_of Core::Propagation::Carrier::ExtractionError, result.error
      assert_equal :oversized, result.error.status
      assert_equal "carrier payload exceeds max_bytes", result.error.reason
      assert_equal "carrier payload exceeds max_bytes", result.error.message
    end

    def test_extract_result_applies_default_max_bytes
      payload = " " * (Core::Propagation::Carrier::DEFAULT_MAX_BYTES + 1)

      result = Core::Propagation::Carrier.extract_result({ "julewire" => payload })

      assert_equal :oversized, result.status
      assert_equal "carrier payload exceeds max_bytes", result.reason
    end

    def test_extraction_error_exposes_status_reason_and_message
      error = Core::Propagation::Carrier::ExtractionError.new(:bad_status, "bad reason")

      assert_equal :bad_status, error.status
      assert_equal "bad reason", error.reason
      assert_equal "bad reason", error.message
    end

    def test_restore_applies_extracted_envelope_for_block
      carrier = {
        "julewire" => JSON.generate("context" => { "request_id" => "request-1" })
      }

      observed = Core::Propagation::Carrier.restore(carrier) { Julewire.context.to_h }

      assert_equal({ request_id: "request-1" }, observed)
      assert_empty Julewire.context.to_h
    end

    def test_restore_accepts_custom_key
      carrier = {
        "x-julewire" => JSON.generate("context" => { "request_id" => "request-1" })
      }

      observed = Core::Propagation::Carrier.restore(carrier, key: "x-julewire") { Julewire.context.to_h }

      assert_equal({ request_id: "request-1" }, observed)
      assert_empty Julewire.context.to_h
    end

    def test_inject_accepts_custom_key
      carrier = Core::Propagation::Carrier.inject({}, envelope: { context: { id: "1" } }, key: "x-julewire")
      payload = JSON.parse(carrier.fetch("x-julewire"))

      assert_equal "1", payload.dig("context", "id")
    end

    def test_inject_clears_stale_symbol_key_when_writing_fresh_string_key
      carrier = { julewire: "stale-symbol" }

      result = Core::Propagation::Carrier.inject(carrier, envelope: { context: { id: "1" } })

      assert_same carrier, result
      assert_nil carrier[:julewire]
      assert_equal "1", JSON.parse(carrier.fetch("julewire")).dig("context", "id")
    end

    def test_inject_with_symbol_key_writes_string_key
      carrier = {}

      result = Core::Propagation::Carrier.inject(carrier, envelope: { context: { id: "1" } }, key: :x_julewire)

      assert_same carrier, result
      assert_nil carrier[:x_julewire]
      assert_equal "1", JSON.parse(carrier.fetch("x_julewire")).dig("context", "id")
    end

    def test_inject_falls_back_to_assignment_when_delete_fails
      carrier = Class.new(Hash) do
        def delete(_key)
          raise "delete failed"
        end
      end.new
      carrier[:julewire] = "stale-symbol"

      Core::Propagation::Carrier.inject(carrier, envelope: { context: { id: "1" } })

      assert_nil carrier[:julewire]
      assert_equal "1", JSON.parse(carrier.fetch("julewire")).dig("context", "id")
    end

    def test_inject_creates_default_carrier
      carrier = Core::Propagation::Carrier.inject(envelope: { context: { id: "1" } })

      assert_instance_of Hash, carrier
      assert_equal "1", JSON.parse(carrier.fetch("julewire")).dig("context", "id")
    end

    def test_extract_accepts_custom_key
      carrier = {
        "x-julewire" => JSON.generate("context" => { "request_id" => "request-1" })
      }

      envelope = Core::Propagation::Carrier.extract_envelope(carrier, key: "x-julewire")

      assert_equal "request-1", envelope.dig(:context, :request_id)
    end

    def test_encode_serializes_custom_envelopes
      encoded = Core::Propagation::Carrier.encode(envelope: { context: { at: Time.utc(2026, 1, 1) } })

      payload = JSON.parse(encoded)

      assert_equal "2026-01-01T00:00:00.000000000Z", payload.dig("context", "at")
    end

    def test_encode_without_explicit_envelope_captures_current_context
      encoded = Julewire.context.with(request_id: "request-1") { Core::Propagation::Carrier.encode }

      assert_equal "request-1", JSON.parse(encoded).dig("context", "request_id")
    end

    def test_encode_returns_nil_when_envelope_exceeds_max_bytes
      encoded = Core::Propagation::Carrier.encode(envelope: { context: { id: "1234567890" } }, max_bytes: 10)

      assert_nil encoded
    end

    def test_encode_accepts_exact_max_bytes
      envelope = { context: { id: "1" } }
      encoded = Core::Propagation::Carrier.encode(envelope: envelope)

      assert_equal encoded, Core::Propagation::Carrier.encode(envelope: envelope, max_bytes: encoded.bytesize)
    end

    def test_encode_validates_max_bytes
      error = assert_raises(ArgumentError) do
        Core::Propagation::Carrier.encode(envelope: {}, max_bytes: 0)
      end

      assert_equal "max_bytes must be nil or a positive Integer", error.message
    end

    def test_inject_leaves_carrier_unchanged_when_envelope_exceeds_max_bytes
      carrier = { "existing" => "value" }

      result = Core::Propagation::Carrier.inject(carrier, envelope: { context: { id: "1234567890" } }, max_bytes: 10)

      assert_nil result
      assert_equal({ "existing" => "value" }, carrier)
    end

    def test_inject_clears_stale_carrier_value_when_envelope_exceeds_max_bytes
      carrier = { "julewire" => "stale", "existing" => "value" }

      result = Core::Propagation::Carrier.inject(carrier, envelope: { context: { id: "1234567890" } }, max_bytes: 10)

      assert_nil result
      assert_equal({ "existing" => "value" }, carrier)
    end

    def test_inject_clears_stale_string_and_symbol_carrier_keys
      carrier = { "julewire" => "stale-string", julewire: "stale-symbol" }

      result = Core::Propagation::Carrier.inject(carrier, envelope: { context: { id: "1234567890" } }, max_bytes: 10)

      assert_nil result
      assert_empty carrier
    end

    def test_inject_clears_stale_values_on_assignment_only_carriers
      assert_inject_clears_stale_values(AssignmentOnlyCarrier.new("julewire" => "stale", julewire: "stale"))
    end

    def test_inject_clears_custom_symbol_key_on_assignment_only_carriers
      carrier = AssignmentOnlyCarrier.new("x_julewire" => "stale", x_julewire: "stale")

      result = Core::Propagation::Carrier.inject(
        carrier,
        envelope: { context: { id: "1234567890" } },
        key: :x_julewire,
        max_bytes: 10
      )

      assert_nil result
      assert_nil carrier["x_julewire"]
      assert_nil carrier[:x_julewire]
    end

    def test_inject_falls_back_to_assignment_when_carrier_delete_fails
      assert_inject_clears_stale_values(DeleteRaisingCarrier.new("julewire" => "stale", julewire: "stale"))
    end

    def test_inject_swallows_assignment_failure_when_clear_fallback_fails
      carrier = AssignmentRaisingCarrier.new("julewire" => "stale", julewire: "stale")

      result = Core::Propagation::Carrier.inject(
        carrier,
        envelope: { context: { id: "1234567890" } },
        max_bytes: 10
      )

      assert_nil result
      assert_equal "stale", carrier["julewire"]
      assert_equal "stale", carrier[:julewire]
    end

    def test_extract_malformed_error_carries_json_parser_backtrace
      result = Core::Propagation::Carrier.extract_result({ "julewire" => "{" })

      refute_empty result.error.backtrace
      assert_match %r{/json/}, result.error.backtrace.first
    end

    def test_serialized_envelope_uses_core_serializer_namespace
      poison = Class.new do
        def self.call(_)
          raise "wrong serializer"
        end
      end

      Julewire::Core::Propagation::Carrier.const_set(:Serializer, poison)

      encoded = Core::Propagation::Carrier.encode(envelope: { context: { id: "1" } })

      assert_equal "1", JSON.parse(encoded).dig("context", "id")
    ensure
      Julewire::Core::Propagation::Carrier.__send__(:remove_const, :Serializer) if
        Julewire::Core::Propagation::Carrier.const_defined?(:Serializer, false)
    end

    def test_inject_requires_mutable_carrier
      error = assert_raises(ArgumentError) do
        Core::Propagation::Carrier.inject(Object.new, envelope: {})
      end

      assert_equal "carrier must support []=", error.message
    end

    def test_restore_does_not_link_executions_by_default
      carrier = {
        "julewire" => JSON.generate("execution" => { "type" => "request", "id" => "request-1" })
      }

      execution_hash = Core::Propagation::Carrier.restore(carrier) do
        Julewire.with_execution(type: :job, id: "job-1", &:execution_hash)
      end

      assert_equal 1, execution_hash.fetch(:depth)
      assert_nil execution_hash[:parent]
    end

    def test_restore_can_link_executions
      carrier = {
        "julewire" => JSON.generate("execution" => { "type" => "request", "id" => "request-1" })
      }

      execution_hash = Core::Propagation::Carrier.restore(carrier, link_executions: true) do
        Julewire.with_execution(type: :job, id: "job-1", &:execution_hash)
      end

      assert_equal 2, execution_hash.fetch(:depth)
      assert_equal "request-1", execution_hash.dig(:parent, :id)
    end

    private

    def assert_inject_clears_stale_values(carrier)
      result = Core::Propagation::Carrier.inject(carrier, envelope: { context: { id: "1234567890" } }, max_bytes: 10)

      assert_nil result
      assert_nil carrier["julewire"]
      assert_nil carrier[:julewire]
    end

    class AssignmentOnlyCarrier
      def initialize(values)
        @values = values
      end

      def [](key) = @values[key]

      def []=(key, value)
        @values[key] = value
      end
    end

    class DeleteRaisingCarrier < AssignmentOnlyCarrier
      def delete(_key)
        raise "delete failed"
      end
    end

    class AssignmentRaisingCarrier < DeleteRaisingCarrier
      def []=(_key, _value)
        raise "assignment failed"
      end
    end
  end
end
