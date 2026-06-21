# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestExceptionSeverity < Minitest::Test
    cover Julewire::Rails::ExceptionSeverity

    def test_normalizes_rails_debug_exception_log_level
      request = request_with_level(::Logger::FATAL)

      assert_equal :fatal, Julewire::Rails::ExceptionSeverity.for_request(request)
      assert_equal ["action_dispatch.debug_exception_log_level"], request.instance_variable_get(:@keys)
      assert_equal :warn, Julewire::Rails::ExceptionSeverity.for_request(request_with_level(:warn))
    end

    def test_defaults_missing_level_to_error
      assert_equal :error, Julewire::Rails::ExceptionSeverity.for_request(request_with_level(nil))
    end

    def test_contains_reader_failures
      request = Object.new
      request.define_singleton_method(:get_header) do |_key|
        raise "header failed"
      end

      assert_equal :error, Julewire::Rails::ExceptionSeverity.for_request(request)
    end

    def test_contains_invalid_header_values
      assert_equal :error, Julewire::Rails::ExceptionSeverity.for_request(request_with_level(:nope))
    end

    private

    def request_with_level(level)
      Object.new.tap do |request|
        request.instance_variable_set(:@keys, [])
        request.define_singleton_method(:get_header) do |key|
          @keys << key
          level
        end
      end
    end
  end
end
