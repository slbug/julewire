# frozen_string_literal: true

module Julewire
  module GCP
    module SourceLocation
      BACKTRACE_PATTERN = /\A(?<file>.+?):(?<line>\d+)(?::in (?:[`'](?<quoted>.*)[`']|(?<plain>.*)))?\z/
      private_constant :BACKTRACE_PATTERN

      class << self
        def call(options)
          values = Core::Integration::Values::Shape
          location = {}
          values.append_field(location, "file", string_value(options[:file]))
          values.append_field(location, "line", line_value(options[:line]))
          values.append_field(location, "function", string_value(options[:function]))
          location unless location.empty?
        end

        def from_error(error)
          return unless error.is_a?(Hash)

          Array(error[:backtrace]).each do |line|
            location = from_backtrace_line(line)
            return location if location
          end
          nil
        end

        def from_backtrace_line(line)
          match = BACKTRACE_PATTERN.match(line.to_s)
          return unless match

          call(
            file: match[:file],
            line: match[:line],
            function: match[:quoted] || match[:plain]
          )
        end

        def string_value(value)
          return if Core::Integration::Values::Read.blank?(value)

          value.to_s
        end

        def line_value(value)
          string = value.to_s
          string if string.match?(/\A\d+\z/)
        end
      end
    end
  end
end
