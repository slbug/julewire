# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      module Chaos
        class RaisingOutput
          def initialize(error, failures:)
            @error = error
            @failures = failures
          end

          def write(value)
            raise @error if @failures.include?(:write)

            value.bytesize
          end

          def flush
            raise @error if @failures.include?(:flush)

            self
          end

          def close
            raise @error if @failures.include?(:close)

            self
          end

          def after_fork!
            raise @error if @failures.include?(:after_fork)

            self
          end
        end

        private_constant :RaisingOutput
      end
    end
  end
end
