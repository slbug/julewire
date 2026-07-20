# frozen_string_literal: true

require "concurrent/atomic/atomic_boolean"
require "concurrent/atomic/atomic_fixnum"

module Julewire
  module Core
    module Diagnostics
      module InvalidSeverityReporter
        @warned = Concurrent::AtomicBoolean.new

        class RuntimeCounter
          def initialize
            @count = Concurrent::AtomicFixnum.new
          end

          def call(value)
            metadata = InvalidSeverityReporter.metadata(value)
            @count.increment
            InvalidSeverityReporter.warn_once(metadata)
          rescue StandardError
            nil
          end

          def health
            { count: @count.value }
          end

          def reset!
            @count.value = 0
          end
        end

        private_constant :RuntimeCounter

        class << self
          def call(value)
            warning_only.call(value)
          end

          def counter = RuntimeCounter.new

          def warn_once(metadata)
            return unless first_warning?

            # Bypass Ruby's verbosity gates; this warning is emitted once.
            Warning.warn("julewire: unsupported record severity #{metadata.fetch(:value_class)}; using :info\n")
          end

          def reset!
            @warned.make_false
          end

          def metadata(value)
            { value_class: value.class.to_s }.freeze
          rescue StandardError
            { value_class: "unknown" }.freeze
          end

          private

          def warning_only
            @warning_only ||= RuntimeCounter.new
          end

          def first_warning?
            @warned.make_true
          end
        end
      end
    end
  end
end
