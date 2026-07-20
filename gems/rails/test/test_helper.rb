# frozen_string_literal: true

require_relative "../../../support/testing/coverage"
Julewire::TestSupport::Coverage.start!

require "julewire/rails"
require_relative "../../../support/testing/method_override"
require_relative "support/julewire/rails/rescued_exception_helpers"
require_relative "support/julewire/rails/test_helpers"

require "minitest/autorun"
require "minitest/strict"
require_relative "../../../support/testing/test_reports"
Julewire::TestSupport::TestReports.start!
require_relative "../../../support/mutant/minitest_coverage"
require "json"
require "stringio"

module Minitest
  class Test
    include Julewire::Rails::RescuedExceptionHelpers
    include Julewire::Rails::TestHelpers

    def setup
      Julewire.reset!
      reset_rails_lifecycle_hooks
      reset_request_summary_timeout_scheduler
    end

    def configure_destination(config, output:, encoder: Julewire::Core::Serialization::JsonEncoder.new,
                              formatter: Julewire::Core::Records::Formatter.new, name: :default,
                              close_output: false, max_record_bytes: Julewire::Core::DEFAULT_MAX_RECORD_BYTES)
      config.destinations.clear if name == :default
      config.destinations.use(
        name,
        close_output: close_output,
        encoder: encoder,
        formatter: formatter,
        max_record_bytes: max_record_bytes,
        output: output
      )
    end
  end
end
