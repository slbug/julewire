# frozen_string_literal: true

module Julewire
  module Core
    module Scheduling
      module SharedScheduler
        THREAD_NAME = "julewire-deadline-scheduler"

        @mutex = Mutex.new

        class << self
          def schedule(timeout, &)
            current = scheduler
            current.schedule(timeout, &)
          end

          def cancel(token)
            current = scheduler
            current.cancel(token)
          end

          def after_fork!
            current = @scheduler
            @mutex = Mutex.new
            current&.after_fork!
            nil
          end

          # Private testing seam for isolating process-wide scheduler state.
          def reset_for_test!
            @mutex.synchronize { @scheduler = nil }
            nil
          end

          private

          private :reset_for_test!

          def scheduler
            @mutex.synchronize do
              @scheduler ||= DeadlineScheduler.new(thread_name: THREAD_NAME)
            end
          end
        end
      end
    end
  end
end
