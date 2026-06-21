# frozen_string_literal: true

module Julewire
  module Core
    module Processing
      class LevelThreshold
        DEFAULT_EVENT = "log"
        DEFAULT_SEVERITY = :info

        attr_reader :level

        def initialize(level:, invalid_severity_reporter: Diagnostics::InvalidSeverityReporter)
          @level = Records::Severity.normalize(level)
          @level_rank = Records::Severity.rank(@level)
          @invalid_severity_reporter = invalid_severity_reporter
        end

        def allow?(severity)
          Records::Severity.rank(severity) >= @level_rank
        end

        def raw_input_allowed?(input)
          return allow?(DEFAULT_SEVERITY) unless Records::RawInput.hash_input?(input)

          severity, invalid, invalid_raw_value = raw_input_severity(input)
          allowed = allow?(severity)
          # Surviving inputs warn later at Records::Draft normalization.
          record_invalid_raw_severity(input, invalid_raw_value) if invalid && !allowed
          allowed
        end

        private

        def raw_input_severity(input)
          return [DEFAULT_SEVERITY, false, nil] unless Records::RawInput.explicit_severity?(input)

          raw_value = Records::RawInput.value(input, :severity)
          [Records::Severity.normalize(raw_value), false, nil]
        rescue ArgumentError
          [DEFAULT_SEVERITY, true, raw_value]
        end

        def record_invalid_raw_severity(input, raw_value)
          @invalid_severity_reporter.call(
            raw_value,
            source: Records::RawInput.value(input, :source),
            event: Records::RawInput.value(input, :event) || DEFAULT_EVENT
          )
        end
      end
    end
  end
end
