# frozen_string_literal: true

require "active_support/isolated_execution_state"

module Julewire
  module Rails
    module Suppression
      KEY = :julewire_rails_suppressed

      class << self
        def active?
          !!::ActiveSupport::IsolatedExecutionState[KEY]
        end

        def suppress
          previous = ::ActiveSupport::IsolatedExecutionState[KEY]
          ::ActiveSupport::IsolatedExecutionState[KEY] = true
          yield
        ensure
          if previous
            ::ActiveSupport::IsolatedExecutionState[KEY] = previous
          else
            ::ActiveSupport::IsolatedExecutionState.delete(KEY)
          end
        end
      end
    end
  end
end
