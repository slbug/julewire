# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestProcessingLevelThreshold < Minitest::Test
    cover Julewire::Core::Processing::LevelThreshold
    def test_valid_below_threshold_raw_input_is_not_reported_as_invalid
      reported = []
      threshold = Core::Processing::LevelThreshold.new(
        level: :warn,
        invalid_severity_reporter: ->(value) { reported << value }
      )

      assert_false threshold.raw_input_allowed?(severity: :debug, message: "quiet")

      assert_empty reported
    end

    def test_level_reader_returns_normalized_severity
      threshold = Core::Processing::LevelThreshold.new(level: "WARN")

      assert_equal :warn, threshold.level
    end

    def test_invalid_below_threshold_raw_input_reports_original_value
      reported = []
      invalid = Object.new
      threshold = Core::Processing::LevelThreshold.new(
        level: :warn,
        invalid_severity_reporter: ->(value) { reported << value }
      )

      assert_false threshold.raw_input_allowed?(severity: invalid, message: "quiet")

      assert_equal [invalid], reported
    end

    def test_implicit_below_threshold_raw_input_is_not_reported_as_invalid
      reported = []
      threshold = Core::Processing::LevelThreshold.new(
        level: :warn,
        invalid_severity_reporter: ->(value) { reported << value }
      )

      assert_false threshold.raw_input_allowed?(message: "quiet")

      assert_empty reported
    end

    def test_invalid_below_threshold_nil_severity_reports_nil
      reported = []
      threshold = Core::Processing::LevelThreshold.new(
        level: :warn,
        invalid_severity_reporter: ->(value) { reported << value }
      )

      assert_false threshold.raw_input_allowed?(severity: nil, message: "quiet")

      assert_equal [nil], reported
    end

    def test_invalid_allowed_raw_input_is_not_reported_before_draft_normalization
      reported = []
      threshold = Core::Processing::LevelThreshold.new(
        level: :debug,
        invalid_severity_reporter: ->(value) { reported << value }
      )

      assert_true threshold.raw_input_allowed?(severity: Object.new, message: "survives")

      assert_empty reported
    end

    def test_default_invalid_severity_reporter_receives_invalid_below_threshold_values
      reported = []
      invalid = Object.new

      with_overridden_singleton_method(
        Core::Diagnostics::InvalidSeverityReporter,
        :call,
        proc { |value| reported << value }
      ) do
        threshold = Core::Processing::LevelThreshold.new(level: :warn)

        assert_false threshold.raw_input_allowed?(severity: invalid, message: "quiet")
      end

      assert_equal [invalid], reported
    end
  end
end
