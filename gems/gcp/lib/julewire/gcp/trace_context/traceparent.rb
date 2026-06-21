# frozen_string_literal: true

module Julewire
  module GCP
    module TraceContext
      module Traceparent
        TRACEPARENT_PATTERN =
          /\A[[:xdigit:]]{2}-[[:xdigit:]]{32}-[[:xdigit:]]{16}-[[:xdigit:]]{2}(?:-.*)?\z/
        MIN_BYTES = 55
        TRACE_ID_OFFSET = 3
        TRACE_ID_BYTES = 32
        SPAN_ID_OFFSET = 36
        SPAN_ID_BYTES = 16
        TRACE_FLAGS_OFFSET = 53
        private_constant :TRACEPARENT_PATTERN,
                         :MIN_BYTES,
                         :TRACE_ID_OFFSET,
                         :TRACE_ID_BYTES,
                         :SPAN_ID_OFFSET,
                         :SPAN_ID_BYTES,
                         :TRACE_FLAGS_OFFSET

        class << self
          def call(value)
            value = value.to_s.scrub.strip
            return unless TRACEPARENT_PATTERN.match?(value)

            parse_value(value)
          end

          private

          def parse_value(value)
            version = value.byteslice(0, 2).downcase
            return if version == "ff"
            return if version == "00" && value.byteslice(MIN_BYTES)

            trace_id = value.byteslice(TRACE_ID_OFFSET, TRACE_ID_BYTES)
            span_id = value.byteslice(SPAN_ID_OFFSET, SPAN_ID_BYTES)
            trace_id.downcase!
            span_id.downcase!
            return if Hex.zero?(trace_id) || Hex.zero?(span_id)

            context(trace_id, span_id, trace_flags(value).allbits?(1))
          end

          def context(trace_id, span_id, sampled)
            {
              trace_id: trace_id,
              span_id: span_id,
              trace_sampled: sampled
            }
          end

          def trace_flags(value)
            Integer(value.byteslice(TRACE_FLAGS_OFFSET, 2), 16)
          end
        end
      end
    end
  end
end
