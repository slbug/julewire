# frozen_string_literal: true

module Julewire
  module GCP
    module SourceLocationOptions
      class << self
        def call(record, neutral_attributes)
          control = record.fetch(:payload)[:gcp]
          return from_neutral_attributes(neutral_attributes) unless control.is_a?(Hash)

          options = control[:source_location]
          return options if options.is_a?(Hash)

          from_neutral_attributes(neutral_attributes)
        end

        def from_neutral_attributes(neutral_attributes)
          file = neutral_attributes[Core::Fields::AttributeKeys::CODE_FILE_PATH]
          line = neutral_attributes[Core::Fields::AttributeKeys::CODE_LINE_NUMBER]
          function = neutral_attributes[Core::Fields::AttributeKeys::CODE_FUNCTION_NAME]
          values = Core::Integration::Values::Shape
          options = {}
          values.append_field(options, :file, file)
          values.append_field(options, :line, line)
          values.append_field(options, :function, function)
          options
        end
      end
    end
  end
end
