# frozen_string_literal: true

require "test_helper"
require "stringio"

module Julewire
  class TestDoctor < Minitest::Test
    cover Julewire::Core::Diagnostics::Doctor
    cover "Julewire::Core::FacadeMethods#doctor"
    class FailingOutput
      def write(_value)
        raise "write failed"
      end
    end

    FakeRuntime = Data.define(:health, :config)
    FakeConfig = Data.define(:level)

    def test_doctor_reports_no_destination_warning
      report = Julewire.doctor

      assert_equal :degraded, report.fetch(:status)
      assert_equal Julewire.config.level, report.dig(:runtime, :level)
      assert_false report.dig(:pipeline, :configured)
      assert_empty report.dig(:pipeline, :destinations)
      assert_includes report.fetch(:warnings), { code: :no_destinations, message: "pipeline has no destinations" }
      refute_includes report.fetch(:warnings), { code: :pipeline_degraded, message: "pipeline is unconfigured" }
    end

    def test_doctor_reports_configured_destinations
      output = StringIO.new
      configure_default_output(output)

      health = Julewire.health
      report = Julewire.doctor

      assert_equal :ok, report.fetch(:status)
      assert_empty report.fetch(:warnings)
      assert_equal [:default], report.dig(:pipeline, :destinations).keys
      assert_equal :ok, report.dig(:pipeline, :destinations, :default, :status)
      assert_equal health.dig(:pipeline, :destinations, :default, :counts),
                   report.dig(:pipeline, :destinations, :default, :counts)
      assert_false report.dig(:pipeline, :destinations, :default).key?(:last_failure)
      assert_false report.dig(:pipeline, :destinations, :default).key?(:last_loss)
    end

    def test_doctor_reports_degraded_destination
      Julewire.configure { configure_destination(it, output: FailingOutput.new) }

      Julewire.emit(message: "boom")
      report = Julewire.doctor
      destination = report.dig(:pipeline, :destinations, :default)
      warnings = report.fetch(:warnings)

      assert_kind_of Hash, destination.fetch(:counts)
      assert_equal :degraded, destination.fetch(:status)
      assert_equal :write, destination.dig(:last_failure, :action)
      assert_equal :output_exception, destination.dig(:last_loss, :reason)
      assert_includes warnings, { code: :destination_degraded, message: "destination default is degraded" }
    end

    def test_doctor_report_preserves_runtime_shape_and_pipeline_warning
      runtime_failure = { phase: :runtime_call, error_class: "RuntimeError" }
      pipeline_failure = { phase: :emit, error_class: "RuntimeError" }
      health = {
        closed: true,
        counts: { emitted: 2, failures: 1 },
        generation: 7,
        integrations: {},
        last_failure: runtime_failure,
        pipeline: {
          configured: true,
          counts: { failures: 1 },
          destinations: {},
          last_failure: pipeline_failure,
          status: :degraded
        },
        process_integrations: {},
        status: :degraded
      }

      report = Julewire::Core::Diagnostics::Doctor.call(FakeRuntime.new(health, FakeConfig.new(:debug)))

      assert_equal :degraded, report.fetch(:status)
      assert_equal(
        {
          closed: true,
          counts: { emitted: 2, failures: 1 },
          generation: 7,
          last_failure: runtime_failure,
          level: :debug,
          status: :degraded
        },
        report.fetch(:runtime)
      )
      assert_equal(
        {
          configured: true,
          counts: { failures: 1 },
          destinations: {},
          last_failure: pipeline_failure,
          status: :degraded
        },
        report.fetch(:pipeline)
      )
      assert_equal pipeline_failure, report.dig(:pipeline, :last_failure)
      assert_includes report.fetch(:warnings), { code: :pipeline_degraded, message: "pipeline is degraded" }
      refute_includes report.fetch(:warnings), { code: :no_destinations, message: "pipeline has no destinations" }
    end

    def test_doctor_report_preserves_false_closed_and_absent_runtime_failure
      health = {
        closed: false,
        counts: { emitted: 0 },
        generation: 1,
        integrations: {},
        pipeline: {
          configured: true,
          counts: {},
          destinations: {},
          status: :ok
        },
        process_integrations: {},
        status: :ok
      }

      runtime = Julewire::Core::Diagnostics::Doctor.call(FakeRuntime.new(health, FakeConfig.new(:info))).fetch(:runtime)

      assert_false runtime.fetch(:closed)
      assert_nil runtime.fetch(:last_failure)
    end

    def test_doctor_compacts_integration_health_components
      failure = { class: "RuntimeError", phase: :integration }
      health = {
        closed: false,
        counts: {},
        generation: 2,
        integrations: {
          rails: { counts: { failures: 1 }, extra: :raw, last_failure: failure, status: :degraded }
        },
        pipeline: {
          configured: true,
          counts: {},
          destinations: {},
          status: :ok
        },
        process_integrations: {
          active_job: { counts: { failures: 0 }, extra: :raw, last_failure: nil, status: :ok }
        },
        status: :degraded
      }

      report = Julewire::Core::Diagnostics::Doctor.call(FakeRuntime.new(health, FakeConfig.new(:info)))

      assert_equal(
        { counts: { failures: 1 }, last_failure: failure, status: :degraded },
        report.dig(:integrations, :rails)
      )
      assert_equal(
        { counts: { failures: 0 }, status: :ok },
        report.dig(:process_integrations, :active_job)
      )
      refute_includes report.dig(:integrations, :rails), :extra
      refute_includes report.dig(:process_integrations, :active_job), :extra
    end

    def test_doctor_treats_optional_component_failure_and_loss_as_absent
      health = {
        closed: false,
        counts: {},
        generation: 2,
        integrations: {
          rack: { counts: {}, status: :ok }
        },
        pipeline: {
          configured: true,
          counts: {},
          destinations: {
            custom: { counts: {}, status: :ok }
          },
          status: :ok
        },
        process_integrations: {},
        status: :ok
      }

      report = Julewire::Core::Diagnostics::Doctor.call(FakeRuntime.new(health, FakeConfig.new(:info)))

      assert_equal({ counts: {}, status: :ok }, report.dig(:integrations, :rack))
      assert_equal({ counts: {}, status: :ok }, report.dig(:pipeline, :destinations, :custom))
    end

    def test_doctor_reports_all_warning_sources_in_order
      health = {
        closed: true,
        counts: {},
        generation: 2,
        integrations: {
          rails: { counts: {}, last_failure: nil, status: :degraded }
        },
        pipeline: {
          configured: true,
          counts: {},
          destinations: {
            healthy: { counts: {}, last_failure: nil, last_loss: nil, status: :ok },
            output: { counts: {}, last_failure: nil, last_loss: nil, status: :degraded }
          },
          status: :degraded
        },
        process_integrations: {
          active_job: { counts: {}, last_failure: nil, status: :degraded }
        },
        status: :degraded
      }

      warnings = Julewire::Core::Diagnostics::Doctor.call(
        FakeRuntime.new(health, FakeConfig.new(:info))
      ).fetch(:warnings)

      assert_equal(
        [
          { code: :runtime_closed, message: "runtime is closed" },
          { code: :pipeline_degraded, message: "pipeline is degraded" },
          { code: :destination_degraded, message: "destination output is degraded" },
          { code: :integration_degraded, message: "integration rails is degraded" },
          { code: :integration_degraded, message: "process_integration active_job is degraded" }
        ],
        warnings
      )
    end

    def test_doctor_reports_destination_last_loss
      Julewire.configure { configure_destination(it, output: StringIO.new, max_record_bytes: 10) }

      Julewire.emit(message: "too large")
      destination = Julewire.doctor.dig(:pipeline, :destinations, :default)

      assert_kind_of Hash, destination.fetch(:counts)
      assert_equal :degraded, destination.fetch(:status)
      assert_equal :record_too_large, destination.dig(:last_loss, :reason)
      assert_false destination.key?(:last_failure)
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
      assert_kind_of Hash, report.dig(:process_integrations, :web, :counts)
      assert_equal :install, report.dig(:process_integrations, :web, :last_failure, :action)
      assert_false report.dig(:process_integrations, :web).key?(:last_loss)
      assert_includes report.fetch(:warnings),
                      { code: :integration_degraded, message: "process_integration web is degraded" }
    end
  end
end
