# frozen_string_literal: true

module Julewire
  module GCP
    module SourceLocation
      FUNCTION_SEPARATOR = ":in "
      QUOTE_BYTES = [39, 96].freeze
      private_constant :FUNCTION_SEPARATOR, :QUOTE_BYTES

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
          line = line.to_s
          index = line.rindex(FUNCTION_SEPARATOR)
          if index
            location = line.byteslice(0, index)
            function = line.byteslice(index + FUNCTION_SEPARATOR.bytesize, line.bytesize)
          else
            location = line
            function = nil
          end
          file, line_number = split_file_and_line(location)
          return unless line_number

          call(
            file: file,
            line: line_number,
            function: normalize_function(function)
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

        def split_file_and_line(location)
          index = location.rindex(":")
          return unless index

          file = location.byteslice(0, index)
          line = location.byteslice(index + 1, location.bytesize)
          return if file.empty? || !line.match?(/\A\d+\z/)

          [file, line]
        end

        def normalize_function(function)
          return unless function

          if function.bytesize >= 2 && quoted?(function.getbyte(0)) && quoted?(function.getbyte(-1))
            function.byteslice(1, function.bytesize - 2)
          else
            function
          end
        end

        def quoted?(byte)
          QUOTE_BYTES.include?(byte)
        end
      end
    end
  end
end
