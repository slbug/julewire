# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestOutputBranchEdges < Minitest::Test
    def test_string_keyed_raw_severity_drops_before_context_lookup
      output = StringIO.new

      Julewire.configure do |config|
        config.level = :info
        configure_destination(config, output: output)
      end

      assert_nil Julewire.emit("severity" => "debug", "message" => "debug")
      assert_empty output.string
    end

    def test_nil_output_is_a_true_no_op
      Julewire.configure do |config|
        config.destinations.clear
      end

      assert_nil Julewire.emit(message: "discarded")
      assert_empty Julewire.health.fetch(:pipeline).fetch(:destinations)
      refute Julewire.health.dig(:pipeline, :configured)
    end
  end

  class TestFieldSetBranchEdges < Minitest::Test
    cover Julewire::Core::Fields::FieldSet

    def test_field_set_keeps_non_string_non_symbol_keys_distinct
      target = { "1" => "string", safe: true }

      Julewire::Core::Fields::FieldSet.merge!(target, 1 => "integer")

      assert_equal "string", target["1"]
      assert_equal "integer", target[1]
      assert target[:safe]
    end

    def test_field_set_coerce_ignores_invalid_non_hash_fields
      assert_empty Julewire::Core::Fields::FieldSet.coerce("ignored", invalid: :ignore)
    end

    def test_field_set_coerce_accepts_keyword_only_fields
      assert_equal(
        { request_id: "req-1" },
        Julewire::Core::Fields::FieldSet.coerce(nil, { "request_id" => "req-1" })
      )
    end

    def test_owned_summary_attribute_merge_preserves_nested_hashes
      scope = build_execution_scope(type: :unit)

      scope.add_summary_attributes({ payload: { existing: true } }, owned: true)
      scope.add_summary_attributes({ payload: { added: true } }, owned: true)

      assert_equal(
        { existing: true, added: true },
        scope.summary_record_input.dig(:attributes, :payload)
      )
    end
  end

  class TestRecordBranchEdges < Minitest::Test
    def test_record_normalizes_nil_input_and_non_exception_errors
      nil_record = build_record(nil, context: {}, scope: nil)
      string_error_record = build_record({ error: "boom" }, context: {}, scope: nil)
      nil_backtrace_record = build_record({ error: RuntimeError.new("boom") }, context: {}, scope: nil)

      assert_equal "log", nil_record[:event]
      assert_nil nil_record[:message]
      assert_equal({ message: "boom" }, string_error_record[:error])
      assert_nil nil_backtrace_record.dig(:error, :backtrace)
    end
  end
end
