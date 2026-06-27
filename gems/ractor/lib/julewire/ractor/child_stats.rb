# frozen_string_literal: true

require "concurrent/atomic/atomic_fixnum"
require "concurrent/atomic/atomic_reference"

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
        @counters = COUNTER_KEYS.to_h { [it, Concurrent::AtomicFixnum.new] }
        @last_error_class = Concurrent::AtomicReference.new
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
        @counters.each_value { it.value = 0 }
        @last_error_class.set(nil)
      end

      def to_h
        {
          counts: @counters.transform_values(&:value).freeze,
          last_error_class: @last_error_class.get
        }.compact.freeze
      end

      private

      def increment(key)
        @counters.fetch(key).increment
        nil
      end

      def record_error(key, error)
        @counters.fetch(key).increment
        @last_error_class.set(error.class.name)
        nil
      end
    end

    private_constant :ChildStats
  end
end
