# frozen_string_literal: true

module Julewire
  module GCP
    module HttpRequestFields
      class << self
        def http_request(record, attributes)
          values = Core::Integration::Values::Shape
          request = {}
          values.append_field(request, "requestMethod", attributes[Core::Fields::AttributeKeys::HTTP_REQUEST_METHOD])
          values.append_field(
            request,
            "requestUrl",
            attributes[Core::Fields::AttributeKeys::URL_FULL] || attributes[Core::Fields::AttributeKeys::URL_PATH]
          )
          values.append_field(request, "status", attributes[Core::Fields::AttributeKeys::HTTP_RESPONSE_STATUS_CODE])
          values.append_field(request, "userAgent", attributes[Core::Fields::AttributeKeys::USER_AGENT_ORIGINAL])
          values.append_field(request, "remoteIp", attributes[Core::Fields::AttributeKeys::CLIENT_ADDRESS])
          values.append_field(
            request,
            "responseSize",
            int64_string(attributes[Core::Fields::AttributeKeys::HTTP_RESPONSE_BODY_SIZE])
          )
          return if request.empty?

          latency_value = latency(record)
          request["latency"] = latency_value if latency_value
          request
        end

        private

        def latency(record)
          duration_ms = record.fetch(:metrics)[:duration_ms]
          seconds = Float(duration_ms) / 1000
          "#{format("%.9f", seconds).sub(/0+\z/, "").delete_suffix(".")}s"
        rescue ArgumentError, TypeError
          nil
        end

        def int64_string(value)
          Integer(value).to_s
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
