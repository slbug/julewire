# frozen_string_literal: true

require "json"

module Julewire
  module Rack
    module Capture
      module JsonBody
        BODY_KEYS = { request: :request_body, response: :response_body }.freeze
        BODY_BYTES_KEYS = { request: :request_body_bytes, response: :response_body_bytes }.freeze
        BODY_TRUNCATED_KEYS = { request: :request_body_truncated, response: :response_body_truncated }.freeze
        JSON_KEYS = { request: :request_body_json, response: :response_body_json }.freeze
        PARSE_ERROR_KEYS = { request: :request_body_parse_error, response: :response_body_parse_error }.freeze

        class << self
          def fields(prefix, body, bytes:, truncated:, mode:)
            fields = {
              BODY_BYTES_KEYS.fetch(prefix) => bytes,
              BODY_TRUNCATED_KEYS.fetch(prefix) => truncated
            }
            return fields_with_raw_body(fields, prefix, body) unless mode == Settings::JSON_BODY
            return fields if truncated

            append_parsed_fields(fields, prefix, body)
          end

          private

          def fields_with_raw_body(fields, prefix, body)
            fields[BODY_KEYS.fetch(prefix)] = body
            fields
          end

          def append_parsed_fields(fields, prefix, body)
            fields[JSON_KEYS.fetch(prefix)] = JSON.parse(body)
            fields
          rescue JSON::ParserError => e
            fields[PARSE_ERROR_KEYS.fetch(prefix)] = e.class.name
            fields
          end
        end
      end
    end
  end
end
