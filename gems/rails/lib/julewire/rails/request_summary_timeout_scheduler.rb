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

        def after_fork!
          Core::Scheduling::SharedScheduler.after_fork!
        end
      end
    end
  end
end
