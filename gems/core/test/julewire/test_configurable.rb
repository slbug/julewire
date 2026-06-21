# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestConfigurable < Minitest::Test
    module Example
      class Configuration
        attr_accessor :value
      end

      module Adapter
        extend Core::Integration::Configurable

        configurable_with { Configuration }
      end
    end

    def test_configurable_with_requires_block
      error = assert_raises(ArgumentError) do
        Module.new { extend Core::Integration::Configurable }.configurable_with
      end

      assert_equal "configuration class block required", error.message
    end

    def setup
      super
      Example::Adapter.reset!
    end

    def test_configure_requires_block
      error = assert_raises(ArgumentError) { Example::Adapter.configure }

      assert_equal "Julewire::TestConfigurable::Example::Adapter.configure requires a block", error.message
    end

    def test_configure_yields_current_configuration
      configuration = Example::Adapter.configure { it.value = "configured" }

      assert_same configuration, Example::Adapter.config
      assert_equal "configured", Example::Adapter.config.value
    end

    def test_config_assignment_and_reset
      configuration = Example::Configuration.new

      Example::Adapter.config = configuration
      Example::Adapter.reset!

      refute_same configuration, Example::Adapter.config
    end

    def test_config_assignment_rejects_wrong_type
      error = assert_raises(TypeError) { Example::Adapter.config = Object.new }

      assert_equal "expected Julewire::TestConfigurable::Example::Configuration", error.message
    end
  end
end
