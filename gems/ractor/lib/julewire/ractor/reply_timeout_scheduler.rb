# frozen_string_literal: true

module Julewire
  module Ractor
    class ReplyTimeoutScheduler
      THREAD_NAME = "julewire-ractor-reply-timeout"

      def initialize(timeout_value:)
        @timeout_value = timeout_value
      end

      def schedule(reply, timeout:)
        Thread.new(Float(timeout)) do |delay|
          Thread.current.name = THREAD_NAME
          sleep(delay)
          send_timeout(reply)
        end
      end

      def cancel(thread)
        thread&.kill
        thread&.join
        nil
      end

      def with_timeout(reply, timeout:)
        token = schedule(reply, timeout: timeout)
        yield
      ensure
        cancel(token)
      end

      private

      def send_timeout(reply)
        reply.send(@timeout_value)
      rescue StandardError
        nil
      end
    end
  end
end
