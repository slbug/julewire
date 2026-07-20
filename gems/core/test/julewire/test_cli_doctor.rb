# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

module Julewire
  class TestCLIDoctor < Minitest::Test
    cover Julewire::Core::CLI::Doctor
    def test_doctor_prints_json_report
      result = run_cli(%w[doctor])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_true result.stdout.end_with?("\n")
      report = JSON.parse(result.stdout)

      assert_equal "degraded", report.fetch("status")
      assert_includes report.fetch("warnings"), {
        "code" => "no_destinations",
        "message" => "pipeline has no destinations"
      }
    end

    def test_doctor_punk_prints_text_report
      result = run_cli(%w[doctor --punk --no-color])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "!! JULEWIRE DOCTOR !!"
      assert_includes result.stdout, "XX status=DEGRADED XX"
      assert_match(/^runtime level=debug generation=\d+ closed=false$/, result.stdout)
      assert_includes result.stdout, "pipeline configured=false status=unconfigured"
      assert_includes result.stdout, "destinations=none"
      assert_includes result.stdout, "!! warnings=1"
      assert_includes result.stdout, "!! no_destinations: pipeline has no destinations"
      refute_includes result.stdout, "\e["
    end

    def test_doctor_plain_theme_does_not_force_text_report
      result = run_cli(%w[doctor --plain])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_equal "degraded", JSON.parse(result.stdout).fetch("status")
    end

    def test_doctor_json_after_punk_wins_by_option_order
      result = run_cli(%w[doctor --punk --json])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_equal "degraded", JSON.parse(result.stdout).fetch("status")
    end

    def test_doctor_text_prints_component_statuses_and_warning_rows
      Julewire.configure do |config|
        configure_destination(config, output: StringIO.new)
        configure_destination(config, name: :audit, output: StringIO.new)
      end
      Julewire::Core::Integration::Health.record_failure(
        :active_job,
        RuntimeError.new("subscriber failed"),
        component: :subscriber
      )
      Julewire::Core::Integration::Health.record_failure(
        :rails,
        RuntimeError.new("logger failed"),
        component: :logger
      )

      result = run_cli(%w[doctor --text --no-color])
      lines = result.stdout.lines(chomp: true)

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_equal "Julewire Doctor", lines.fetch(0)
      runtime_line = lines.fetch(2)

      assert_match(/^runtime level=debug generation=\d+ closed=false$/, runtime_line)
      assert_equal "pipeline configured=true status=ok", lines.fetch(3)
      assert_includes lines, "destinations=default:ok,audit:ok"
      assert_includes lines, "runtime_integrations=none"
      assert_includes lines, "process_integrations=active_job:degraded,rails:degraded"
      assert_includes lines, "warnings=2"
      assert_includes lines, "- integration_degraded: process_integration active_job is degraded"
      assert_includes lines, "- integration_degraded: process_integration rails is degraded"
      assert_equal(
        [
          "warnings=2",
          "- integration_degraded: process_integration active_job is degraded",
          "- integration_degraded: process_integration rails is degraded"
        ],
        lines.last(3)
      )
      assert_equal result.stdout, "#{lines.join("\n")}\n"
    end

    def test_doctor_plain_text_keeps_plain_theme_when_theme_is_truthy
      result = run_cli(%w[doctor --plain --text --color])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "Julewire Doctor"
      assert_includes result.stdout, "\e[31mstatus=degraded\e[0m"
      assert_includes result.stdout, "warnings=1"
      assert_includes result.stdout, "- no_destinations: pipeline has no destinations"
      refute_includes result.stdout, "!!"
      refute_includes result.stdout, "XX status=DEGRADED XX"
    end

    def test_doctor_text_colorizes_status
      result = run_cli(%w[doctor --text --color])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "\e[31mstatus=degraded\e[0m"
    end

    def test_doctor_text_reports_ok_status_and_no_warnings
      output = StringIO.new
      Julewire.configure { configure_destination(it, output: output) }

      result = run_cli(%w[doctor --text --color])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "\e[32mstatus=ok\e[0m"
      assert_includes result.stdout, "warnings=none"
    end

    def test_doctor_punk_colorizes_status_with_punk_theme
      result = run_cli(%w[doctor --punk --color])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, "\e[91mXX status=DEGRADED XX\e[0m"
    end

    def test_doctor_punk_uses_info_glyph_for_ok_status
      output = StringIO.new
      Julewire.configure { configure_destination(it, output: output) }

      result = run_cli(%w[doctor --punk --no-color])

      assert_equal 0, result.status
      assert_empty result.stderr
      assert_includes result.stdout, ">> status=OK >>"
    end

    def test_doctor_text_defaults_to_color_for_tty_stdout
      stdout = StringIO.new
      stdout.define_singleton_method(:tty?) { true }

      status, stderr = call_doctor_text(stdout)

      assert_equal 0, status
      assert_empty stderr.string
      assert_includes stdout.string, "\e[31mstatus=degraded\e[0m"
    end

    def test_doctor_text_defaults_to_no_color_for_non_tty_stdout
      stdout = StringIO.new
      stdout.define_singleton_method(:tty?) { false }

      status, stderr = call_doctor_text(stdout)

      assert_equal 0, status
      assert_empty stderr.string
      refute_includes stdout.string, "\e["
      assert_includes stdout.string, "status=degraded"
    end

    def test_doctor_text_allows_stdout_without_tty_predicate
      stdout = Class.new do
        attr_reader :string

        def initialize
          @string = +""
        end

        def write(value)
          @string << value
        end
      end.new

      status, stderr = call_doctor_text(stdout)

      assert_equal 0, status
      assert_empty stderr.string
      refute_includes stdout.string, "\e["
    end

    def test_doctor_colorization_uses_internal_text_encoder_constants
      without_constant(Julewire, :TextEncoder) do
        plain = run_cli(%w[doctor --text --color])
        punk = run_cli(%w[doctor --punk --color])

        assert_equal 0, plain.status
        assert_empty plain.stderr
        assert_includes plain.stdout, "\e[31mstatus=degraded\e[0m"
        assert_equal 0, punk.status
        assert_empty punk.stderr
        assert_includes punk.stdout, "\e[91mXX status=DEGRADED XX\e[0m"
      end
    end

    def test_doctor_rejects_unknown_option
      result = run_cli(%w[doctor --corporate])

      assert_equal 1, result.status
      assert_empty result.stdout
      assert_includes result.stderr, "julewire: unknown option --corporate"
    end

    private

    def call_doctor_text(stdout)
      stderr = StringIO.new
      status = Julewire::Core::CLI.call(
        argv: %w[doctor --text],
        stdin: StringIO.new,
        stdout: stdout,
        stderr: stderr
      )

      [status, stderr]
    end
  end
end
