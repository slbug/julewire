# frozen_string_literal: true

module Julewire
  module Core
    module Diagnostics
      module InvalidSeverityReporter
        @warned = false
        @mutex = Mutex.new

        class RuntimeCounter
          def initialize
            @mutex = Mutex.new
            @count = 0
            @last = nil
          end

          def call(value, source: nil, event: nil)
            metadata = InvalidSeverityReporter.metadata(value, source: source, event: event)
            @mutex.synchronize do
              @count += 1
              @last = metadata
            end
            InvalidSeverityReporter.warn_once(metadata)
          rescue StandardError
            nil
          end

          def health
            @mutex.synchronize do
              {
                count: @count,
                last_event: @last&.fetch(:event, nil),
                last_source: @last&.fetch(:source, nil),
                last_value_class: @last&.fetch(:value_class, nil)
              }.compact
            end
          end

          def reset!
            @mutex.synchronize do
              @count = 0
              @last = nil
            end
            nil
          end

          def reset_after_fork!
            @mutex = Mutex.new
            @count = 0
            @last = nil
            nil
          end
        end

        private_constant :RuntimeCounter

        class << self
          def call(value, source: nil, event: nil)
            warning_only.call(value, source: source, event: event)
          rescue StandardError
            nil
          end

          def counter = RuntimeCounter.new

          def warn_once(metadata)
            return unless first_warning?

            # Bypass Ruby's verbosity gates; this warning is emitted once.
            Warning.warn("julewire: unsupported record severity #{metadata.fetch(:value_class)}; using :info\n")
          end

          def reset!
            @mutex.synchronize { @warned = false }
            nil
          end

          def reset_after_fork!
            @mutex = Mutex.new
            @warned = false
            nil
          end

          def metadata(value, source:, event:)
            {
              event: event,
              source: source,
              value_class: value.class.name || value.class.to_s
            }.compact.freeze
          rescue StandardError
            { value_class: "unknown" }.freeze
          end

          private

          def warning_only
            @warning_only ||= RuntimeCounter.new
          end

          def first_warning?
            @mutex.synchronize do
              return false if @warned

              @warned = true
              true
            end
          end
        end
      end
    end
  end
end
