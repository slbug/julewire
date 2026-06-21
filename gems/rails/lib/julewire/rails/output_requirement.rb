# frozen_string_literal: true

module Julewire
  module Rails
    module OutputRequirement
      MESSAGE = "julewire-rails installed Rails.logger, but Julewire has no configured destinations. " \
                "Configure Julewire.destinations or set config.julewire_rails.require_output = false."

      class << self
        def check!(settings, health: Julewire.health, warning: Warning)
          return unless settings.logger?

          mode = normalized_mode(settings.require_output)
          return if mode == false || health.dig(:pipeline, :configured)

          case mode
          when :warn
            warning.warn("#{MESSAGE}\n")
          when :raise
            raise Error, MESSAGE
          end
        end

        private

        def normalized_mode(value)
          case value
          when false, nil then false
          when true, :warn, "warn" then :warn
          when :raise, "raise" then :raise
          else
            raise Error, "config.julewire_rails.require_output must be false, :warn, or :raise"
          end
        end
      end
    end
  end
end
