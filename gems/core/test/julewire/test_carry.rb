# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestCarry < Minitest::Test
    cover Julewire::Core::Fields::FieldStack

    def test_carry_add_is_available_to_formatters_but_omitted_from_default_logs
      records = capture_julewire_records { emit_with_carry }

      assert_equal "trace-1", records.first.dig(:carry, :http, :request_headers, :traceparent)

      output = StringIO.new
      Julewire.configure { configure_destination(it, output: output) }
      emit_with_carry

      point = JSON.parse(output.string.lines.first)
      summary = JSON.parse(output.string.lines.last)

      refute point.key?("carry")
      refute summary.key?("carry")
    end

    def test_carry_with_cleans_up_after_the_block
      Julewire.carry.add(trace: { id: "trace-1" })

      inside = nil
      Julewire.carry.with(job: { id: "job-1" }) do
        inside = Julewire.carry.to_h
      end

      assert_equal "trace-1", inside.dig(:trace, :id)
      assert_equal "job-1", inside.dig(:job, :id)
      assert_equal({ trace: { id: "trace-1" } }, Julewire.carry.to_h)
    end

    def test_carry_delete_removes_nested_fields
      Julewire.carry.add(
        http: {
          request_headers: {
            authorization: "secret",
            traceparent: "trace-1"
          }
        }
      )

      Julewire.carry.delete(:http, :request_headers, :authorization)

      assert_equal "trace-1", Julewire.carry.to_h.dig(:http, :request_headers, :traceparent)
      refute Julewire.carry.to_h.dig(:http, :request_headers).key?(:authorization)
    end

    def test_persistent_carry_delete_masks_scoped_with_overlay_until_added_back
      Julewire.carry.delete(:http, :request_headers, :authorization)

      Julewire.carry.with(
        http: {
          request_headers: {
            authorization: "secret",
            traceparent: "trace-1"
          }
        }
      ) do
        inside = Julewire.carry.to_h

        refute inside.dig(:http, :request_headers).key?(:authorization)
        assert_equal "trace-1", inside.dig(:http, :request_headers, :traceparent)
      end

      Julewire.carry.add(http: { request_headers: { authorization: "restored" } })

      assert_equal "restored", Julewire.carry.to_h.dig(:http, :request_headers, :authorization)
    end

    def test_carry_without_masks_inherited_fields_for_the_block
      Julewire.carry.add(http: { request_headers: { traceparent: "trace-1" } })

      inside = nil
      Julewire.carry.without(:http, :request_headers, :traceparent) do
        inside = Julewire.carry.to_h
      end

      refute inside.dig(:http, :request_headers)&.key?(:traceparent)
      assert_equal "trace-1", Julewire.carry.to_h.dig(:http, :request_headers, :traceparent)
    end

    def test_carry_delete_inside_execution_masks_fields_for_formatters
      records = capture_julewire_records do
        emit_with_authorization_removed
      end

      point = records.first
      summary = records.last

      assert_equal "trace-1", point.dig(:carry, :http, :request_headers, :traceparent)
      refute point.dig(:carry, :http, :request_headers).key?(:authorization)
      refute summary.dig(:carry, :http, :request_headers).key?(:authorization)
    end

    def test_record_formatter_omits_carry_by_default
      formatted = JSON.parse(
        Julewire::Core::Serialization::JsonEncoder.new.call(Julewire::Core::Records::Formatter.new.call(record_with_carry))
      )

      refute formatted.key?("carry")
    end

    def test_carry_delete_inside_execution_is_omitted_from_default_logs
      output = StringIO.new
      Julewire.configure { configure_destination(it, output: output) }

      emit_with_authorization_removed

      point = JSON.parse(output.string.lines.first)
      summary = JSON.parse(output.string.lines.last)

      refute point.key?("carry")
      refute summary.key?("carry")
    end

    private

    def emit_with_carry
      Julewire.with_execution(type: :request) do
        Julewire.carry.add(http: { request_headers: { traceparent: "trace-1" } })
        Julewire.emit(message: "inside")
      end
    end

    def emit_with_authorization_removed
      Julewire.carry.add(http: { request_headers: { authorization: "secret", traceparent: "trace-1" } })
      Julewire.with_execution(type: :request) do
        Julewire.carry.delete(:http, :request_headers, :authorization)
        Julewire.emit(message: "inside")
      end
    end

    def record_with_carry
      build_record(
        { message: "hello" },
        context: {},
        carry: { http: { request_headers: { traceparent: "trace-1" } } },
        scope: nil
      )
    end
  end
end
