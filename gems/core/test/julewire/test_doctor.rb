# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestDoctor < Minitest::Test
    cover Julewire::Core::Diagnostics::Doctor
    cover Julewire::Core::Diagnostics::FailureSnapshot

    class FailingOutput
      def write(_value)
        raise "write failed"
      end
    end

    def test_doctor_reports_no_destination_warning
      report = Julewire.doctor

      assert_equal :degraded, report.fetch(:status)
      assert_equal Julewire.config.level, report.dig(:runtime, :level)
      assert_empty report.dig(:pipeline, :destinations)
      assert_includes report.fetch(:warnings), { code: :no_destinations, message: "pipeline has no destinations" }
      refute_includes report.fetch(:warnings), { code: :pipeline_degraded, message: "pipeline is unconfigured" }
    end

    def test_doctor_reports_configured_destinations
      output = StringIO.new
      configure_default_output(output)

      report = Julewire.doctor

      assert_equal :ok, report.fetch(:status)
      assert_empty report.fetch(:warnings)
      assert_equal [:default], report.dig(:pipeline, :destinations).keys
      assert_equal :ok, report.dig(:pipeline, :destinations, :default, :status)
    end

    def test_doctor_reports_degraded_destination
      Julewire.configure { configure_destination(it, output: FailingOutput.new) }

      Julewire.emit(message: "boom")
      warnings = Julewire.doctor.fetch(:warnings)

      assert_includes warnings, { code: :destination_degraded, message: "destination default is degraded" }
    end

    def test_doctor_reports_process_integration_warnings
      Julewire::Core::Integration::Health.record_failure(
        :web,
        RuntimeError.new("install failed"),
        component: :subscriber,
        action: :install
      )

      report = Julewire.doctor

      assert_empty report.fetch(:integrations)
      assert_equal :degraded, report.dig(:process_integrations, :web, :status)
      assert_includes report.fetch(:warnings),
                      { code: :integration_degraded, message: "process_integration web is degraded" }
    end
  end
end
