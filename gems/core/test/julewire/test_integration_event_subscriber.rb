# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestIntegrationEventSubscriber < Minitest::Test
    cover Julewire::Core::Integration::EventSubscriber
    class FakeConfiguration
      attr_reader :source

      def initialize(source = "default")
        @source = source
      end
    end

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

    def test_event_subscriber_declaration_exposes_default_options
      subscriber_class = build_subscriber_class
      configuration = subscriber_class.default_configuration

      assert_instance_of FakeConfiguration, configuration
      assert_equal "default", configuration.source
      assert_equal :event_subscriber, subscriber_class.event_subscriber_component
      assert_same FakeHealth, subscriber_class.event_subscriber_health
    end

    def test_event_subscriber_declaration_accepts_custom_component
      subscriber_class = build_subscriber_class(component: :custom_event_subscriber)
      subscriber = subscriber_class.new(FakeConfiguration.new("test"))

      assert_nil subscriber.emit(:bad)
      assert_equal(
        [{ action: :emit, component: :custom_event_subscriber, error: "RuntimeError" }],
        FakeHealth.failures
      )
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

    def test_event_subscriber_initializes_with_default_configuration
      subscriber = FakeSubscriber.new

      subscriber.emit(:ok)

      assert_equal [[:ok, "default"]], subscriber.events
      assert_equal 1, subscriber.configuration_changes
    end

    def test_event_subscriber_contains_emit_failures
      subscriber = FakeSubscriber.new(FakeConfiguration.new("test"))

      assert_nil subscriber.emit(:bad)
      assert_equal(
        [{ action: :emit, component: :event_subscriber, error: "RuntimeError" }],
        FakeHealth.failures
      )
    end

    private

    def build_subscriber_class(component: nil)
      Class.new do
        include Core::Integration::EventSubscriber

        if component
          event_subscriber(
            integration_health: FakeHealth,
            configuration_class: FakeConfiguration,
            component: component
          )
        else
          event_subscriber integration_health: FakeHealth, configuration_class: FakeConfiguration
        end

        private

        def emit_event(event)
          raise "bad event" if event == :bad
        end
      end
    end
  end
end
