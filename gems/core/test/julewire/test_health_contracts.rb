# frozen_string_literal: true

require "json"
require "test_helper"
require "stringio"

module Julewire
  class HealthFixtureFailingOutput
    def write(_value)
      raise "write failed"
    end
  end

  class TestHealthContracts < Minitest::Test
    def test_unconfigured_output_reports_degraded_runtime_status
      health = Julewire.health

      assert_equal :degraded, health.fetch(:status)
      assert_equal :unconfigured, health.dig(:pipeline, :status)
      refute health.dig(:pipeline, :configured)
    end

    def test_unconfigured_health_matches_fixture
      fixture = health_fixture("unconfigured")
      actual = JSON.parse(JSON.generate(Julewire::Core::Runtime.new.health))

      assert_equal fixture, actual
    end

    def test_configured_degraded_health_matches_fixture
      runtime = Julewire::Core::Runtime.new
      runtime.configure { it.destinations.use(:default, output: HealthFixtureFailingOutput.new) }

      runtime.emit(message: "output")

      assert_equal health_fixture("configured_degraded"), normalize_health(JSON.parse(JSON.generate(runtime.health)))
    end

    def test_closed_runtime_reports_closed_status
      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
      end

      Julewire.close(timeout: 1)
      health = Julewire.health

      assert_equal :closed, health.fetch(:status)
      assert health.fetch(:closed)
    end

    private

    def health_fixture(name)
      fixture_path = File.expand_path("../fixtures/health/#{name}.json", __dir__)
      JSON.parse(File.read(fixture_path))
    end

    def normalize_health(health)
      destination = health.dig("pipeline", "destinations", "default")
      destination["last_failure"]["at"] = "<timestamp>" if destination&.dig("last_failure", "at")
      destination["last_loss"]["at"] = "<timestamp>" if destination&.dig("last_loss", "at")
      health
    end
  end
end
