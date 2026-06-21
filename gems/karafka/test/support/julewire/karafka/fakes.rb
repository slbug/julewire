# frozen_string_literal: true

module Julewire
  module KarafkaTestSupport
    class MutableMessage
      attr_reader :topic, :partition, :offset, :key
      attr_accessor :headers

      def initialize(topic, partition, offset, headers, key: nil)
        @topic = topic
        @partition = partition
        @offset = offset
        @headers = headers
        @key = key
      end
    end

    class RaisingReader
      def public_send(_method_name)
        raise "reader failed"
      end

      def respond_to?(_method_name, _include_private = false) = true # rubocop:disable Style/OptionalBooleanParameter -- Ruby API shape.
    end

    class RaisingPayload
      def to_h
        raise "payload failed"
      end

      def respond_to?(method_name, include_private = false) # rubocop:disable Style/OptionalBooleanParameter -- Ruby API shape.
        method_name == :to_h || super
      end
    end

    class BadHash < Hash
      def transform_keys(&)
        raise "bad hash"
      end
    end

    class BadMessage
      def headers
        raise "headers failed"
      end
    end

    class FlakyMonitor
      attr_reader :subscriptions

      def initialize(error)
        @error = error
        @subscriptions = []
        @attempts = 0
      end

      def subscribe(event_name, &)
        @attempts += 1
        raise @error if @attempts == 1

        @subscriptions << event_name
      end
    end

    class FakeMonitor
      attr_reader :subscriptions

      def initialize(available_events = nil)
        @subscriptions = []
        @callbacks = Hash.new { |hash, key| hash[key] = [] }
        @available_events = available_events
      end

      def instrument(_event_id, _payload = {})
        yield
      end

      def subscribe(event_name, &block)
        @subscriptions << event_name
        @callbacks[event_name] << block if block
        nil
      end

      def unsubscribe(listener_or_block)
        @subscriptions.delete_if do |event_name|
          @callbacks[event_name].delete(listener_or_block)
          @callbacks[event_name].empty?
        end
        nil
      end

      def publish(event_name, event = FakeEvent.new)
        @callbacks.fetch(event_name, []).each { it.call(event) }
      end

      def available_events
        @available_events || raise(NoMethodError)
      end
    end

    class EventFlakyMonitor < FakeMonitor
      def initialize(error, fail_events:)
        super()
        @error = error
        @fail_events = Array(fail_events)
      end

      def subscribe(event_name, &)
        raise @error if @fail_events.include?(event_name)

        super
      end
    end

    class BasicMonitor
      attr_reader :subscriptions

      def initialize
        @subscriptions = []
      end

      def subscribe(event_name, &)
        @subscriptions << event_name
      end
    end

    class FakeMonitorWithDangerousListeners < FakeMonitor
      def listeners
        raise "listener scanning is not part of the integration contract"
      end
    end

    class FakeMiddleware
      attr_reader :items

      def initialize
        @items = []
      end

      def prepend(item)
        @items.unshift(item)
      end
    end

    class FakeProducer
      attr_reader :middleware, :monitor

      def initialize(monitor = FakeMonitor.new)
        @middleware = FakeMiddleware.new
        @monitor = monitor
      end
    end

    class FakeEvent
      attr_reader :payload

      def initialize(payload = {})
        @payload = payload
      end
    end
  end
end
