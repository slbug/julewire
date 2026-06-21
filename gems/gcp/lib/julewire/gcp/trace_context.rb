# frozen_string_literal: true

module Julewire
  module GCP
    module TraceContext
      X_CLOUD_TRACE_PATTERN = %r{\A([[:xdigit:]]{32})(?:/(\d+))?(?:;o=(\d+))?\z}
      TRACEPARENT_HEADER = "traceparent"
      X_CLOUD_TRACE_CONTEXT_HEADER = "x-cloud-trace-context"
      X_CLOUD_TRACE_CONTEXT_UNDERSCORE_HEADER = "x_cloud_trace_context"
      MAX_SPAN_ID = (2**64) - 1
      DIRECT_HEADER_KEYS = {
        traceparent: [:traceparent, TRACEPARENT_HEADER],
        x_cloud_trace_context: [
          :x_cloud_trace_context,
          X_CLOUD_TRACE_CONTEXT_UNDERSCORE_HEADER,
          X_CLOUD_TRACE_CONTEXT_HEADER
        ]
      }.freeze
      CANONICAL_HEADER_NAMES = {
        traceparent: TRACEPARENT_HEADER,
        x_cloud_trace_context: X_CLOUD_TRACE_CONTEXT_HEADER
      }.freeze
      private_constant :DIRECT_HEADER_KEYS, :CANONICAL_HEADER_NAMES

      module Hex
        class << self
          def zero?(value)
            offset = 0
            while offset < value.bytesize
              return false unless value.getbyte(offset) == 48

              offset += 1
            end
            true
          end
        end
      end
      private_constant :Hex

      class << self
        def extract(headers)
          return {} unless headers.respond_to?(:[])

          parse_traceparent(fetch_header(headers, :traceparent)) ||
            parse_x_cloud_trace_context(fetch_header(headers, :x_cloud_trace_context)) ||
            {}
        end

        def parse_traceparent(value)
          Traceparent.call(value)
        end

        def parse_x_cloud_trace_context(value)
          match = X_CLOUD_TRACE_PATTERN.match(value.to_s.scrub.strip)
          return unless match

          trace_id = match[1].downcase
          return if Hex.zero?(trace_id)

          context = { trace_id: trace_id }
          if match[2]
            span_id = decimal_span_to_hex(match[2])
            context[:span_id] = span_id if span_id
          end
          context[:trace_sampled] = Integer(match[3], 10).allbits?(1) if match[3]
          context
        end

        private

        def fetch_header(headers, key)
          DIRECT_HEADER_KEYS.fetch(key).each do |header_key|
            value = headers[header_key]
            return value unless value.nil?
          end
          return unless headers.respond_to?(:each)

          canonical_name = CANONICAL_HEADER_NAMES.fetch(key)
          headers.each do |name, value|
            return value if normalize_header_name(name) == canonical_name
          end
          nil
        end

        def normalize_header_name(name)
          normalized = name.to_s.dup
          normalized.tr!("_", "-")
          normalized.downcase!
          normalized
        end

        def decimal_span_to_hex(value)
          integer = Integer(value, 10)
          return if integer > MAX_SPAN_ID

          span_id = integer.to_s(16).rjust(16, "0")
          return if Hex.zero?(span_id)

          span_id
        end
      end
    end
  end
end
