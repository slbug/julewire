# frozen_string_literal: true

require "concurrent/atomic/atomic_fixnum"
require "concurrent/atomic/atomic_reference"

module Julewire
  module Ractor
    module Bridge
      module Stats
        @active_threads = Concurrent::AtomicFixnum.new(0)
        @failure_count = Concurrent::AtomicFixnum.new(0)
        @last_error = Concurrent::AtomicReference.new
        @message_count = Concurrent::AtomicFixnum.new(0)
        @started_threads = Concurrent::AtomicFixnum.new(0)
        @stopped_threads = Concurrent::AtomicFixnum.new(0)

        class << self
          def bridge_started
            @active_threads.increment
            @started_threads.increment
          end

          def bridge_stopped(error = nil)
            @active_threads.decrement if @active_threads.value.positive?
            @stopped_threads.increment
            record_failure(error) if error
          end

          def message_received
            @message_count.increment
          end

          def message_failed(error)
            record_failure(error)
          end

          def health
            {
              active_threads: @active_threads.value,
              experimental: true,
              failure_count: @failure_count.value,
              last_error_class: @last_error.get&.fetch(:class),
              messages: @message_count.value,
              started_threads: @started_threads.value,
              stopped_threads: @stopped_threads.value
            }.compact
          end

          def reset!
            # Active bridge threads are live state; reset history without
            # forcing a running bridge to later decrement a cleared counter.
            @failure_count.value = 0
            @last_error.set(nil)
            @message_count.value = 0
            @started_threads.value = 0
            @stopped_threads.value = 0
            nil
          end

          def after_fork!
            @active_threads.value = 0
            reset!
          end

          private

          def record_failure(error)
            @failure_count.increment
            @last_error.set({ class: error.class.name })
          end
        end
      end
    end
  end
end
