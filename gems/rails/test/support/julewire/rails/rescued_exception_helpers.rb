# frozen_string_literal: true

module Julewire
  module Rails
    module RescuedExceptionHelpers
      def define_rescued_exception(name, status)
        exception_class = Class.new(StandardError)
        Object.const_set(name, exception_class)
        update_rescue_responses { it[name] = status }
        exception_class
      end

      def remove_rescued_exception(name)
        update_rescue_responses { it.delete(name) }
        Object.__send__(:remove_const, name) if Object.const_defined?(name, false)
      end

      private

      def update_rescue_responses
        responses = ActionDispatch::ExceptionWrapper.rescue_responses
        responses = responses.dup if responses.frozen?
        yield responses
        ActionDispatch::ExceptionWrapper.rescue_responses = responses
      end
    end
  end
end
