# frozen_string_literal: true

module Julewire
  module Ractor
    class ChildStats
      COUNTER_KEYS = %i[
        messages_dropped
        messages_sent
        requests_failed
        requests_sent
        requests_timed_out
      ].freeze
      private_constant :COUNTER_KEYS

      def initialize
        @mutex = Mutex.new
        @counters = COUNTER_KEYS.to_h { [it, 0] }
      end

      def message_sent = increment(:messages_sent)

      def message_dropped(error)
        record_error(:messages_dropped, error)
      end

      def request_sent = increment(:requests_sent)

      def request_failed(error)
        record_error(:requests_failed, error)
      end

      def request_timed_out = increment(:requests_timed_out)

      def reset!
        @mutex.synchronize do
          @counters.each_key { @counters[it] = 0 }
          @last_error_class = nil
        end
        nil
      end

      def to_h
        @mutex.synchronize do
          {
            counts: @counters.dup.freeze,
            last_error_class: @last_error_class
          }.compact.freeze
        end
      end

      private

      def increment(key)
        @mutex.synchronize { @counters[key] += 1 }
        nil
      end

      def record_error(key, error)
        @mutex.synchronize do
          @counters[key] += 1
          @last_error_class = error.class.name
        end
        nil
      end
    end

    private_constant :ChildStats
  end
end
