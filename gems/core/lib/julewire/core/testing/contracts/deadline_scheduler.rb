# frozen_string_literal: true

require "timeout"

module Julewire
  module Core
    module Testing
      module Contracts
        module DeadlineScheduler
          def assert_julewire_deadline_scheduler_spi_contract
            scheduler = Julewire::Core::Scheduling::DeadlineScheduler.new(thread_name: "julewire-contract-deadline")
            called = false

            result = scheduler.schedule(0) { called = true }

            assert called
            assert_nil result
            assert_nil scheduler.cancel(nil)
            assert_scheduler_runs_callbacks(scheduler)
            assert_scheduler_cancel_suppresses_callback(scheduler)
            assert_scheduler_after_fork_resets_pending_callbacks(scheduler)
          end

          private

          def assert_scheduler_runs_callbacks(scheduler)
            queue = Queue.new

            scheduler.schedule(0.001) { queue << :done }

            assert_equal :done, Timeout.timeout(1) { queue.pop }
          end

          def assert_scheduler_cancel_suppresses_callback(scheduler)
            queue = Queue.new
            token = scheduler.schedule(0.01) { queue << :cancelled }

            scheduler.cancel(token)
            scheduler.schedule(0.02) { queue << :sentinel }

            assert_equal :sentinel, Timeout.timeout(1) { queue.pop }
            assert_empty Julewire::Core::Testing.nonblocking_queue_values(queue)
          end

          def assert_scheduler_after_fork_resets_pending_callbacks(scheduler)
            queue = Queue.new

            scheduler.schedule(0.01) { queue << :old }
            assert_same scheduler, scheduler.after_fork!
            scheduler.schedule(0.001) { queue << :new }

            assert_equal :new, Timeout.timeout(1) { queue.pop }
            assert_empty Julewire::Core::Testing.nonblocking_queue_values(queue)
          end
        end
      end
    end
  end
end
