# frozen_string_literal: true

require "test_helper"
require "json"

module Julewire
  class TestCarrier < Minitest::Test
    cover Julewire::Core::Propagation::Carrier

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

      envelope = Core::Propagation::Carrier.extract(carrier)

      assert_equal "request-1", envelope.dig(:context, :request_id)
      assert_equal "trace-1", envelope.dig(:carry, :trace, :id)
    end

    def test_extract_accepts_symbol_carrier_key
      carrier = {
        julewire: JSON.generate("context" => { "request_id" => "request-1" })
      }

      envelope = Core::Propagation::Carrier.extract(carrier)

      assert_equal "request-1", envelope.dig(:context, :request_id)
    end

    def test_extract_returns_empty_for_missing_or_unsupported_carrier
      assert_empty Core::Propagation::Carrier.extract({})
      assert_empty Core::Propagation::Carrier.extract(Object.new)
    end

    def test_restore_applies_extracted_envelope_for_block
      carrier = {
        "julewire" => JSON.generate("context" => { "request_id" => "request-1" })
      }

      observed = Core::Propagation::Carrier.restore(carrier) { Julewire.context.to_h }

      assert_equal({ request_id: "request-1" }, observed)
      assert_empty Julewire.context.to_h
    end

    def test_extract_ignores_invalid_payloads
      assert_empty Core::Propagation::Carrier.extract({ "julewire" => "{" })
      assert_empty Core::Propagation::Carrier.extract({ "julewire" => "[]" })
    end

    def test_extract_result_reports_invalid_payload_status
      assert_extract_failure_status("{", :malformed, extraction_error: true)
    end

    def test_extract_result_reports_non_hash_payload_status
      assert_extract_failure_status("[1,2,3]", :non_hash, extraction_error: true)
    end

    def test_extract_ignores_oversized_payload_before_parsing
      payload = JSON.generate("context" => { "request_id" => "request-1" })

      assert_empty Core::Propagation::Carrier.extract({ "julewire" => payload }, max_bytes: payload.bytesize - 1)
    end

    def test_extract_defaults_to_carrier_byte_limit
      payload = JSON.generate("context" => { "blob" => "x" * Core::Propagation::Carrier::DEFAULT_MAX_BYTES })

      assert_empty Core::Propagation::Carrier.extract({ "julewire" => payload })
    end

    def test_extract_allows_explicit_unbounded_raw_payload_limit
      payload = JSON.generate("context" => { "blob" => "x" * Core::Propagation::Carrier::DEFAULT_MAX_BYTES })

      envelope = Core::Propagation::Carrier.extract({ "julewire" => payload }, max_bytes: nil)

      assert_match(/\Ax+\.\.\.\[Truncated\]\z/, envelope.dig(:context, :blob))
    end

    def test_extract_accepts_payload_at_exact_max_bytes_limit
      payload = JSON.generate("context" => { "request_id" => "request-1" })

      envelope = Core::Propagation::Carrier.extract({ "julewire" => payload }, max_bytes: payload.bytesize)

      assert_equal "request-1", envelope.dig(:context, :request_id)
    end

    def test_extract_result_reports_oversized_payload_status
      payload = JSON.generate("context" => { "request_id" => "request-1" })

      assert_extract_failure_status(payload, :oversized, max_bytes: payload.bytesize - 1)
    end

    def test_restore_ignores_oversized_payload
      payload = JSON.generate("context" => { "request_id" => "request-1" })
      carrier = { "julewire" => payload }

      observed = Core::Propagation::Carrier.restore(carrier, max_bytes: payload.bytesize - 1) do
        Julewire.context.to_h
      end

      assert_empty observed
    end

    def test_restore_defaults_to_carrier_byte_limit
      payload = JSON.generate("context" => { "blob" => "x" * Core::Propagation::Carrier::DEFAULT_MAX_BYTES })
      carrier = { "julewire" => payload }

      observed = Core::Propagation::Carrier.restore(carrier) { Julewire.context.to_h }

      assert_empty observed
    end

    def test_restore_accepts_payload_at_exact_max_bytes_limit
      payload = JSON.generate("context" => { "request_id" => "request-1" })
      carrier = { "julewire" => payload }

      observed = Core::Propagation::Carrier.restore(carrier, max_bytes: payload.bytesize) do
        Julewire.context.to_h
      end

      assert_equal({ request_id: "request-1" }, observed)
    end

    def test_extract_validates_max_bytes
      error = assert_raises(ArgumentError) do
        Core::Propagation::Carrier.extract({}, max_bytes: 0)
      end

      assert_equal "max_bytes must be nil or a positive Integer", error.message
    end

    def test_inject_accepts_custom_key
      carrier = Core::Propagation::Carrier.inject({}, envelope: { context: { id: "1" } }, key: "x-julewire")
      payload = JSON.parse(carrier.fetch("x-julewire"))

      assert_equal "1", payload.dig("context", "id")
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

      envelope = Core::Propagation::Carrier.extract(carrier, key: "x-julewire")

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

    def test_encode_validates_max_bytes
      assert_raises(ArgumentError) do
        Core::Propagation::Carrier.encode(envelope: {}, max_bytes: 0)
      end
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

    def assert_extract_failure_status(payload, status, max_bytes: nil, extraction_error: false)
      options = {}
      options[:max_bytes] = max_bytes if max_bytes
      result = Core::Propagation::Carrier.extract_result({ "julewire" => payload }, **options)

      assert_empty result.envelope
      assert_predicate result, :failure?
      assert_equal status, result.status
      assert_instance_of Core::Propagation::Carrier::ExtractionError, result.error if extraction_error
    end

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
  end
end
