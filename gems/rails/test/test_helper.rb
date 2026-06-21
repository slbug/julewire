# frozen_string_literal: true

require "julewire/core/testing/coverage"
Julewire::Core::Testing::Coverage.start!

require "julewire/rails"
require "julewire/core/testing"
require_relative "support/julewire/rails/rescued_exception_helpers"
require_relative "support/julewire/rails/test_helpers"

require "minitest/autorun"
require "mutant/minitest/coverage"
require "json"
require "stringio"

module Minitest
  class Test
    include Julewire::Core::Testing::Contracts
    include Julewire::Rails::RescuedExceptionHelpers
    include Julewire::Rails::TestHelpers

    def setup
      Julewire.reset!
      Julewire::Rails::LifecycleHooks.__send__(:reset_for_test!)
      Julewire::Rails::RequestSummaryTimeoutScheduler.__send__(:reset_for_test!)
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
