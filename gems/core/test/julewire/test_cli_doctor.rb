# frozen_string_literal: true

require "test_helper"
require "json"

module Julewire
  class TestCLIDoctor < Minitest::Test
    cover Julewire::Core::CLI::Doctor

    def test_doctor_prints_json_report
      result = run_cli(%w[doctor])

      assert_equal 0, result.status
      assert_empty result.stderr
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
      assert_includes result.stdout, "runtime level="
      assert_includes result.stdout, "pipeline configured="
      assert_includes result.stdout, "destinations=none"
      assert_includes result.stdout, "!! warnings=1"
      assert_includes result.stdout, "!! no_destinations: pipeline has no destinations"
    end

    def test_doctor_rejects_unknown_option
      result = run_cli(%w[doctor --corporate])

      assert_equal 1, result.status
      assert_empty result.stdout
      assert_includes result.stderr, "julewire: unknown option --corporate"
    end
  end
end
