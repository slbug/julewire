# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRactorRemoteSummaryRecord < Minitest::Test
    cover Julewire::Ractor::RemoteSummaryRecord

    def test_owned_summary_record_input_preserves_symbol_keyed_record
      input = {
        severity: "info",
        context: { request_id: "request-1" },
        payload: [{ processed: 1 }]
      }
      record = Julewire::Ractor::RemoteSummaryRecord.new(input)

      assert_same input, record.owned_summary_record_input
    end

    def test_owned_summary_record_input_rejects_string_keys
      record = Julewire::Ractor::RemoteSummaryRecord.new(event: { "name" => "done" })

      assert_raises(TypeError) { record.owned_summary_record_input }
    end
  end
end
