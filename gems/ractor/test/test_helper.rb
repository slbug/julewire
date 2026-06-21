# frozen_string_literal: true

require "julewire/core/testing/coverage"
Julewire::Core::Testing::Coverage.start!(filters: [%r{/lib/julewire/ractor/destination_worker\.rb\z}])

require "julewire/ractor"
require "julewire/core/testing"

require "minitest/autorun"
require "mutant/minitest/coverage"

module Minitest
  class Test
    include Julewire::Core::Testing::Contracts

    def setup
      Julewire.reset!
      Julewire::Ractor::Bridge.reset!
    end

    def configure_direct_destination(
      config,
      output:,
      encoder: Julewire::Core::Serialization::JsonEncoder.new,
      formatter: Julewire::Core::Records::Formatter.new,
      name: :default
    )
      config.destinations.add(
        Julewire::Core::Destinations::Destination.new(
          name: name,
          close_output: false,
          encoder: encoder,
          formatter: formatter,
          max_record_bytes: Julewire::Core::DEFAULT_MAX_RECORD_BYTES,
          on_drop: config.on_drop,
          on_failure: config.on_failure,
          output: output,
          processors: []
        )
      )
    end

    def nonblocking_queue_values(queue) = Julewire::Core::Testing.nonblocking_queue_values(queue)

    def with_overridden_singleton_method(receiver, method_name, replacement, &)
      Julewire::Core::Testing.with_overridden_singleton_method(receiver, method_name, replacement, &)
    end
  end
end
