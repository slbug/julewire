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
        rescue StandardError
          nil
        end

        def mark(error)
          return unless error

          errors = error_map
          each_exception(error) { errors[it] = true }
        rescue StandardError
          nil
        end

        def consume?(error)
          errors = current_error_map
          return false unless errors

          each_exception(error).any? { errors.delete(it) }
        rescue StandardError
          false
        end

        private

        def error_map
          current_error_map || set_error_map
        end

        def set_error_map
          ObjectSpace::WeakKeyMap.new.tap { ::ActiveSupport::IsolatedExecutionState[KEY] = it }
        end

        def current_error_map
          ::ActiveSupport::IsolatedExecutionState[KEY]
        end

        def each_exception(error)
          return enum_for(:each_exception, error) unless block_given?

          seen = {}.compare_by_identity
          while error && !seen.key?(error)
            yield error
            seen[error] = true
            error = error.cause
          end
        end
      end
    end
  end
end
