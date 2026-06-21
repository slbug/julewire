# frozen_string_literal: true

module Julewire
  module Ractor
    class ReplyTimeoutScheduler
      THREAD_NAME = "julewire-ractor-reply-timeout"

      # This stays stdlib-only because RemoteRuntime creates it inside a Ractor.
      # Concurrent::ScheduledTask currently touches non-shareable concurrent-ruby
      # constants from worker ractors.

      def initialize(timeout_value:)
        @timeout_value = timeout_value
        @scheduler = Core::Scheduling::DeadlineScheduler.new(thread_name: THREAD_NAME, idle: :exit)
      end

      def schedule(reply, timeout:)
        @scheduler.schedule(timeout) { send_timeout(reply) }
      end

      def cancel(token)
        return unless token

        @scheduler.cancel(token)
      rescue StandardError
        nil
      end

      private

      def send_timeout(reply)
        reply.send(@timeout_value)
        nil
      rescue StandardError
        nil
      end
    end
  end
end
