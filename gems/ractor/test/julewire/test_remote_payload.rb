# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRactorRemotePayload < Minitest::Test
    cover Julewire::Ractor::RemotePayload

    class HashSubclass < Hash
    end

    def test_extracts_input_and_sections_from_string_keys
      payload = Julewire::Ractor::RemotePayload.extract(
        "input" => "done",
        "context" => { "request_id" => "r1" },
        "neutral" => { "messaging.system" => "kafka" },
        "attributes" => { "ractor" => { "child" => true } },
        "carry" => { "traceparent" => "trace-1" }
      )

      assert_equal "done", payload.fetch(:input)
      assert_equal({ request_id: "r1" }, payload.fetch(:context))
      assert_equal({ "messaging.system": "kafka" }, payload.fetch(:neutral))
      assert_equal({ ractor: { child: true } }, payload.fetch(:attributes))
      assert_equal({ traceparent: "trace-1" }, payload.fetch(:carry))
    end

    def test_extracts_scope_snapshot_from_string_keys
      payload = Julewire::Ractor::RemotePayload.extract(
        "scope" => {
          "execution" => { "type" => "ractor", "id" => "child-1" },
          "neutral" => { "messaging.system" => "kafka" },
          "attributes" => { "ractor" => { "child" => true } },
          "carry" => { "traceparent" => "trace-1" },
          "labels" => { "worker" => "child" }
        }
      )
      scope = payload.fetch(:scope)

      assert_instance_of Julewire::Core::Execution::ScopeSnapshot, scope
      assert_equal({ type: "ractor", id: "child-1" }, scope.execution_hash)
      assert_equal({ "messaging.system": "kafka" }, scope.neutral_hash)
      assert_equal({ ractor: { child: true } }, scope.attributes_hash)
      assert_equal({ traceparent: "trace-1" }, scope.carry_hash)
      assert_equal({ worker: "child" }, scope.labels_hash)
    end

    def test_rejects_non_hash_payloads_and_sections
      payload = Julewire::Ractor::RemotePayload.extract(
        "context" => "bad",
        "neutral" => nil,
        "attributes" => [],
        "carry" => Object.new,
        "scope" => "bad"
      )

      assert_equal({}, payload.fetch(:input))
      assert_equal({}, payload.fetch(:context))
      assert_equal({}, payload.fetch(:neutral))
      assert_equal({}, payload.fetch(:attributes))
      assert_equal({}, payload.fetch(:carry))
      assert_empty payload.fetch(:scope).execution_hash

      invalid_payload = Julewire::Ractor::RemotePayload.extract("not a hash")

      assert_equal({}, invalid_payload.fetch(:input))
      assert_equal({}, invalid_payload.fetch(:context))
      assert_equal({}, invalid_payload.fetch(:carry))
    end

    def test_accepts_hash_subclass_sections
      payload_hash = HashSubclass.new
      input = HashSubclass.new
      input["message"] = "done"
      payload_hash["input"] = input
      context = HashSubclass.new
      context["request_id"] = "r1"
      payload_hash[:context] = context

      payload = Julewire::Ractor::RemotePayload.extract(payload_hash)

      assert_equal({ message: "done" }, payload.fetch(:input))
      assert_equal({ request_id: "r1" }, payload.fetch(:context))
    end

    def test_extract_normalizes_hash_input_as_owned_bridge_payload
      payload = Julewire::Ractor::RemotePayload.extract(
        "input" => {
          "message" => "done",
          "_julewire_truncation" => {
            "truncated" => true,
            "truncated_fields" => ["message"],
            "limits" => { "max_string_bytes" => 16 }
          }
        }
      )

      assert_equal "done", payload.dig(:input, :message)
      assert_equal ["message"], payload.dig(:input, :_julewire_truncation, :truncated_fields)
    end

    def test_extract_preserves_scalar_input_without_field_bag_normalization
      message = ("x" * (Julewire::Core::Serialization::Serializer::DEFAULT_MAX_STRING_BYTES + 1)).freeze
      payload = Julewire::Ractor::RemotePayload.extract("input" => message)

      assert_same message, payload.fetch(:input)
    end

    def test_extract_preserves_owned_truncation_metadata
      payload = Julewire::Ractor::RemotePayload.extract(
        "context" => {
          "_julewire_truncation" => {
            "truncated" => true,
            "truncated_fields" => ["blob"],
            "limits" => { "max_string_bytes" => 16_384 }
          }
        }
      )

      metadata = payload.dig(:context, :_julewire_truncation)

      assert metadata.fetch(:truncated)
      assert_equal ["blob"], metadata.fetch(:truncated_fields)
      assert_equal 16_384, metadata.dig(:limits, :max_string_bytes)
    end
  end
end
