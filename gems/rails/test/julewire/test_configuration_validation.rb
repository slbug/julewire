# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestConfigurationValidation < Minitest::Test
    cover Julewire::Rails::Configuration
    cover Julewire::Rails::Error
    cover "Julewire::Rails.config"
    cover "Julewire::Rails.configure"

    def test_rails_configure_yields_application_configuration
      configuration = Julewire::Rails::Configuration.new
      app_config = Data.define(:julewire_rails).new(configuration)
      application = Data.define(:config).new(app_config)

      with_overridden_singleton_method(::Rails, :application, proc { application }) do
        returned = Julewire::Rails.configure { it.response_capture.body = true }

        assert_same configuration, returned
        assert_predicate configuration.response_capture, :body?
      end
    end

    def test_rails_configure_requires_block
      error = assert_raises(ArgumentError) { Julewire::Rails.configure }

      assert_equal "Julewire::Rails.configure requires a block", error.message
    end

    def test_rails_config_requires_application
      error = with_overridden_singleton_method(::Rails, :application, proc {}) do
        assert_raises(Julewire::Rails::Error) { Julewire::Rails.config }
      end

      assert_equal "Rails.application is not available", error.message
    end

    def test_configuration_rejects_broad_carry_request_headers
      settings = Julewire::Rails::Configuration.new

      error = assert_raises(Julewire::Rails::Error) { settings.carry_request_headers = true }

      assert_equal "carry_request_headers must be an explicit header list", error.message
    end

    def test_configuration_preserves_explicit_carry_request_header_list
      settings = Julewire::Rails::Configuration.new

      settings.carry_request_headers = %w[traceparent tracestate]

      assert_equal %w[traceparent tracestate], settings.carry_request_headers
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

    def test_configuration_preserves_valid_request_summary_timeouts
      settings = Julewire::Rails::Configuration.new

      settings.request_summary_timeout = 0.25

      assert_in_delta(0.25, settings.request_summary_timeout)

      settings.request_summary_timeout = nil

      assert_nil settings.request_summary_timeout
    end

    def test_configuration_rejects_invalid_request_exclude_prefixes
      settings = Julewire::Rails::Configuration.new

      error = assert_raises(Julewire::Rails::Error) { settings.request_exclude_prefixes = ["tail"] }

      assert_equal "request_exclude_prefixes must contain absolute path prefixes", error.message
    end

    def test_configuration_normalizes_single_request_exclude_prefix
      settings = Julewire::Rails::Configuration.new

      settings.request_exclude_prefixes = "/julewire"

      assert_equal ["/julewire"], settings.request_exclude_prefixes
    end

    def test_configuration_rejects_invalid_capture_body_mode
      settings = Julewire::Rails::Configuration.new

      error = assert_raises(Julewire::Rack::Error) { settings.request_capture.body = "yes" }

      assert_equal "body must be false, true, or :json", error.message
    end

    def test_configuration_validates_and_preserves_capture_settings_objects
      settings = Julewire::Rails::Configuration.new
      calls = []
      capture = Object.new
      capture.define_singleton_method(:validate!) { calls << :validate }

      settings.request_capture = capture

      assert_same capture, settings.request_capture
      assert_equal [:validate], calls
    end
  end
end
