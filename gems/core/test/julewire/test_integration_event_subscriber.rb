# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestIntegrationEventSubscriber < Minitest::Test
    FakeConfiguration = Data.define(:source)

    class FakeHealth
      class << self
        attr_reader :failures, :successes

        def reset
          @failures = []
          @successes = 0
        end

        def with_failure_health(**metadata)
          yield.tap { @successes += 1 }
        rescue StandardError => e
          @failures << metadata.merge(error: e.class.name)
          nil
        end
      end
    end

    class FakeSubscriber
      include Core::Integration::EventSubscriber

      event_subscriber integration_health: FakeHealth, configuration_class: FakeConfiguration

      attr_reader :configuration_changes, :events

      def after_configuration_change
        @configuration_changes = configuration_changes.to_i + 1
      end

      private

      def emit_event(event)
        raise "bad event" if event == :bad

        (@events ||= []) << [event, @configuration.source]
      end
    end

    def setup
      FakeHealth.reset
    end

    def test_event_subscriber_wraps_emit_and_tracks_configuration
      subscriber = FakeSubscriber.new(FakeConfiguration.new("test"))

      subscriber.emit(:ok)

      assert_equal [[:ok, "test"]], subscriber.events
      assert_equal 1, FakeHealth.successes
      assert_equal 1, subscriber.configuration_changes

      subscriber.configuration = FakeConfiguration.new("next")
      subscriber.emit(:again)

      assert_equal [:again, "next"], subscriber.events.last
      assert_equal 2, subscriber.configuration_changes
    end

    def test_event_subscriber_contains_emit_failures
      subscriber = FakeSubscriber.new(FakeConfiguration.new("test"))

      assert_nil subscriber.emit(:bad)
      assert_equal(
        [{ action: :emit, component: :event_subscriber, error: "RuntimeError" }],
        FakeHealth.failures
      )
    end
  end
end
