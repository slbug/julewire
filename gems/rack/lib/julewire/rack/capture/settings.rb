# frozen_string_literal: true

module Julewire
  module Rack
    module Capture
      class Settings
        JSON_BODY = :json
        STRING_BODY = :string
        CAPTURE_BODY_VALUES = [false, true, JSON_BODY, "json"].freeze
        private_constant :CAPTURE_BODY_VALUES

        include Julewire::Core::Integration::Settings

        setting :body, default: false, predicate: true, validate: :validate_body
        setting :body_bytes, default: 65_536, validate: byte_limit
        setting :body_content_types, default: BodyContentType::JSON_ONLY
        setting :headers, default: false, predicate: true

        def body_mode
          case body
          when JSON_BODY, "json"
            JSON_BODY
          else
            STRING_BODY
          end
        end

        def enabled? = headers? || body?

        private

        def validate_body(value)
          return value if CAPTURE_BODY_VALUES.include?(value)

          raise Error, "body must be false, true, or :json"
        end
      end
    end
  end
end
