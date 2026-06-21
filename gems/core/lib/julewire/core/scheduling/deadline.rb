# frozen_string_literal: true

module Julewire
  module Core
    module Scheduling
      module Deadline
        CLOCK = Process::CLOCK_MONOTONIC

        class << self
          def for(timeout)
            Process.clock_gettime(CLOCK) + timeout if timeout
          end

          def remaining(deadline)
            return unless deadline

            remaining = deadline - Process.clock_gettime(CLOCK)
            remaining.positive? ? remaining : 0
          end
        end
      end
    end
  end
end
