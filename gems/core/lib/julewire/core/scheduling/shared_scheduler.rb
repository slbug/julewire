# frozen_string_literal: true

require "concurrent/executor/thread_pool_executor"
require "concurrent/executor/timer_set"

module Julewire
  module Core
    module Scheduling
      module SharedScheduler
        THREAD_NAME = "julewire-deadline-scheduler"
        EXECUTOR_OPTIONS = { max_threads: 1, idletime: 0 }.freeze
        private_constant :EXECUTOR_OPTIONS

        class << self
          def schedule(timeout, &block)
            raise ArgumentError, "block required" unless block

            timeout = Float(timeout)
            if timeout <= 0
              yield
              return
            end

            @scheduler.post(timeout) do
              Thread.current.name = THREAD_NAME
              yield
            end
          end

          def cancel(task)
            task&.cancel
            nil
          end

          def after_fork!
            previous = @scheduler
            @scheduler = build_scheduler
            previous.kill
            nil
          end

          private

          def build_scheduler
            executor = Concurrent::ThreadPoolExecutor.new(**EXECUTOR_OPTIONS)
            Concurrent::TimerSet.new(executor: executor)
          end
        end

        @scheduler = build_scheduler
      end
    end
  end
end
