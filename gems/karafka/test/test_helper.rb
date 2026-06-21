# frozen_string_literal: true

require "julewire/core/testing/coverage"
Julewire::Core::Testing::Coverage.start!

require "karafka"
require "julewire/karafka"
require "julewire/core/testing"
require "karafka/core/helpers/time"
require "karafka/core/monitoring/event"
require "karafka/core/monitoring/monitor"
require "karafka/core/monitoring/notifications"
require "karafka/testing/minitest/helpers"
require "minitest/autorun"
require "julewire/core/testing/test_reports"
Julewire::Core::Testing::TestReports.start!
require "mocha/minitest"
require "mutant/minitest/coverage"
require_relative "support/julewire/karafka/capture"
require_relative "support/julewire/karafka/fakes"

module Julewire
  module KarafkaTestSupport
    class Consumer < ::Karafka::BaseConsumer
      def consume; end
    end

    class App < ::Karafka::App
      setup do |config|
        config.client_id = "julewire-karafka-test"
        config.group_id = "julewire-karafka-test"
        config.kafka = { "bootstrap.servers": "127.0.0.1:9092" }
      end

      routes.draw do
        consumer_group "payments" do
          topic :events do
            consumer Consumer
          end
        end
      end
    end
  end
end

Minitest::Test.include(Karafka::Testing::Minitest::Helpers)
