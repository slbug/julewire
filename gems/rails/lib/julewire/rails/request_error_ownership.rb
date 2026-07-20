# frozen_string_literal: true

require "active_support/isolated_execution_state"

module Julewire
  module Rails
    module RequestErrorOwnership
      KEY = :julewire_rails_request_error_objects
      private_constant :KEY

      class << self
        def clear
          ::ActiveSupport::IsolatedExecutionState.delete(KEY)
        end

        def mark(error)
          each_exception(error) { error_map[it] = true }
        end

        def consume?(error)
          errors = current_error_map
          return false unless errors

          each_exception(error) do |exception|
            return true if errors.delete(exception)
          end
          false
        end

        private

        def error_map
          current_error_map || set_error_map
        end

        def set_error_map
          ObjectSpace::WeakMap.new.tap { ::ActiveSupport::IsolatedExecutionState[KEY] = it }
        end

        def current_error_map
          ::ActiveSupport::IsolatedExecutionState[KEY]
        end

        def each_exception(error, seen = {}.compare_by_identity, &)
          return unless error
          return if seen.key?(error)

          seen[error] = nil
          yield error
          each_exception(error.cause, seen, &)
        end
      end
    end
  end
end
