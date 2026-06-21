# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRactorRemoteSummaryRecord < Minitest::Test
    cover Julewire::Ractor::RemoteSummaryRecord

    def test_owned_summary_record_input_symbolizes_nested_keys
      record = Julewire::Ractor::RemoteSummaryRecord.new(
        "severity" => "info",
        "context" => { "request_id" => "request-1" },
        "payload" => [{ "processed" => 1 }]
      )

      assert_equal(
        {
          severity: "info",
          context: { request_id: "request-1" },
          payload: [{ processed: 1 }]
        },
        record.owned_summary_record_input
      )
    end

    def test_owned_summary_record_input_is_cached
      record = Julewire::Ractor::RemoteSummaryRecord.new("event" => "done")

      assert_same record.owned_summary_record_input, record.owned_summary_record_input
    end
  end
end
