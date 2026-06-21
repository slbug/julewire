# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestLifecycleHooks < Minitest::Test
    include Julewire::Rails::TestHelpers

    def test_lifecycle_hook_reads_shutdown_timeout_when_it_runs
      settings = Julewire::Rails::Configuration.new
      settings.shutdown_timeout = 0.25
      registrar = Julewire::Rails::TestHelpers::FakeAtExit.new
      calls = []

      Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar)
      settings.shutdown_timeout = 0.75

      with_overridden_singleton_method(Julewire, :flush, proc { |timeout:| calls << [:flush, timeout] }) do
        with_overridden_singleton_method(Julewire, :close, proc { |timeout:| calls << [:close, timeout] }) do
          registrar.hooks.fetch(0).call
        end
      end

      assert_equal [[:flush, 0.75], [:close, 0.75]], calls
    end
  end
end
