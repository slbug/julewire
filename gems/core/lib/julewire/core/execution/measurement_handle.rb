# frozen_string_literal: true

require "concurrent/atomic/atomic_boolean"

module Julewire
  module Core
    module Execution
      class MeasurementHandle
        def initialize(&finish)
          @finish = finish
          @finished = Concurrent::AtomicBoolean.new
        end

        def finish
          return unless @finished.make_true

          @finish.call
        end

        def finished? = @finished.true?
      end
    end
  end
end
