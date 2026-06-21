# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestConfigurationValidation < Minitest::Test
    cover Julewire::Rails::Configuration

    def test_configuration_rejects_broad_carry_request_headers
      settings = Julewire::Rails::Configuration.new

      error = assert_raises(Julewire::Rails::Error) { settings.carry_request_headers = true }

      assert_equal "carry_request_headers must be an explicit header list", error.message
    end

    def test_configuration_rejects_invalid_request_summary_timeout
      settings = Julewire::Rails::Configuration.new

      error = assert_raises(Julewire::Rails::Error) { settings.request_summary_timeout = "30" }

      assert_equal "request_summary_timeout must be nil or a positive Numeric", error.message
    end

    def test_configuration_rejects_zero_request_summary_timeout
      settings = Julewire::Rails::Configuration.new

      error = assert_raises(Julewire::Rails::Error) { settings.request_summary_timeout = 0 }

      assert_equal "request_summary_timeout must be nil or a positive Numeric", error.message
    end

    def test_configuration_rejects_invalid_request_exclude_prefixes
      settings = Julewire::Rails::Configuration.new

      error = assert_raises(Julewire::Rails::Error) { settings.request_exclude_prefixes = ["tail"] }

      assert_equal "request_exclude_prefixes must contain absolute path prefixes", error.message
    end

    def test_configuration_rejects_invalid_capture_body_mode
      settings = Julewire::Rails::Configuration.new

      error = assert_raises(Julewire::Rack::Error) { settings.request_capture.body = "yes" }

      assert_equal "body must be false, true, or :json", error.message
    end
  end
end
