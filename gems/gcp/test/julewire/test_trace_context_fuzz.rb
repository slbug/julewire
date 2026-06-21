# frozen_string_literal: true

require "test_helper"
require "json"

module Julewire
  class TestTraceContextFuzz < Minitest::Test
    cover Julewire::GCP::TraceContext
    cover Julewire::GCP::TraceContext::Traceparent

    SEED = 0x20260612
    ITERATIONS = 120

    def test_trace_header_parsers_do_not_raise_for_fixed_random_strings
      random = Random.new(SEED)

      ITERATIONS.times do |index|
        value = random_header_value(random)

        assert_trace_context_shape(GCP::TraceContext.parse_traceparent(value))
        assert_trace_context_shape(GCP::TraceContext.parse_x_cloud_trace_context(value))
      rescue StandardError => e
        flunk("trace parser fuzz seed=#{SEED} index=#{index}: #{e.class}: #{e.message}")
      end
    end

    private

    def assert_trace_context_shape(context)
      return unless context

      assert_kind_of Hash, context
      JSON.generate(context, allow_nan: false)
    end

    def random_header_value(random)
      case random.rand(8)
      when 0 then random_ascii(random)
      when 1 then random_invalid_utf8(random)
      when 2 then random_traceparent_like(random)
      when 3 then random_x_cloud_like(random)
      when 4 then " " * random.rand(0..4)
      when 5 then "#{random_ascii(random)}-#{random_ascii(random)}"
      when 6 then random.rand(10**25).to_s
      end
    end

    def random_traceparent_like(random)
      [
        random_hex(random, 2),
        random_hex(random, 32),
        random_hex(random, 16),
        random_hex(random, 2),
        random_ascii(random)
      ].join("-")
    end

    def random_x_cloud_like(random)
      "#{random_hex(random, 32)}/#{random.rand(10**25)};o=#{random.rand(4)}"
    end

    def random_hex(random, length)
      alphabet = "0123456789abcdefABCDEFxyz"
      Array.new(length) { alphabet[random.rand(alphabet.length)] }.join
    end

    def random_ascii(random)
      Array.new(random.rand(0..80)) { random.rand(32..126).chr }.join
    end

    def random_invalid_utf8(random)
      Array.new(random.rand(1..40)) { random.rand(256) }.pack("C*").force_encoding(Encoding::UTF_8)
    end
  end
end
