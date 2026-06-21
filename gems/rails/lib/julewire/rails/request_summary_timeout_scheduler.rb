# frozen_string_literal: true

module Julewire
  module Rails
    module RequestSummaryTimeoutScheduler
      class << self
        def schedule(timeout, &block)
          return unless timeout && block

          Core::Scheduling::SharedScheduler.schedule(timeout, &block)
        rescue StandardError
          nil
        end

        def cancel(token)
          return unless token

          Core::Scheduling::SharedScheduler.cancel(token)
        rescue StandardError
          nil
        end

        # Private testing seam for request-timeout isolation.
        def reset_for_test!
          Core::Scheduling::SharedScheduler.__send__(:reset_for_test!)
          nil
        end

        def after_fork!
          Core::Scheduling::SharedScheduler.after_fork!
          nil
        end

        private :reset_for_test!
      end
    end
  end
end
