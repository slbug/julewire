# frozen_string_literal: true

require "test_helper"
require "support/gcp_test_case"

module Julewire
  class GcpIntegrationTest < Minitest::Test
    cover Julewire::GCP::Destination
    def test_integrates_as_core_destination_formatter
      output = StringIO.new

      Julewire.configure do |config|
        config.destinations.use(:gcp, formatter: GCP::Formatter.new, output: output)
      end

      Julewire.emit(severity: :info, message: "hello", payload: { value: 1 })

      parsed = JSON.parse(output.string)

      assert_equal "INFO", parsed.fetch("severity")
      assert_equal "hello", parsed.fetch("message")
      assert_equal 1, parsed.fetch("payload").fetch("value")
    end
  end
end
