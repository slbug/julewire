# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestEventSubscriberSummaryFields < Minitest::Test
    def test_request_completion_summary_keeps_missing_duration_absent
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new

      Julewire.with_execution(type: :request, id: "req-1", summary_event: "request.completed") do
        subscriber.emit(
          name: "action_controller.request_completed",
          payload: { status: 204 },
          tags: {},
          context: {}
        )
      end

      attributes = parse_records(output).fetch(0).fetch("attributes").fetch("rails")

      assert_equal 204, attributes.fetch("status")
      refute attributes.key?("duration_ms")
      refute attributes.key?("action_runtime_ms")
    end
  end
end
