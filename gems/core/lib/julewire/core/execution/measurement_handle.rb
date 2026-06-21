# frozen_string_literal: true

module Julewire
  module Core
    module Execution
      class MeasurementHandle
        def initialize(&finish)
          @finish = finish
          @finished = false
          @mutex = Mutex.new
        end

        def finish
          @mutex.synchronize do
            return if @finished

            @finished = true
            @finish.call
          end
        end

        def finished?
          @mutex.synchronize { @finished }
        end
      end
    end
  end
end
