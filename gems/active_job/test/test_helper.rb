# frozen_string_literal: true

require_relative "../../../support/testing/coverage"
Julewire::TestSupport::Coverage.start!

require "rails"
require "julewire/active_job"
require "julewire/core/testing"
require "minitest/autorun"
require "minitest/strict"
require_relative "../../../support/testing/method_override"
require_relative "../../../support/testing/test_reports"
Julewire::TestSupport::TestReports.start!
require_relative "../../../support/mutant/minitest_coverage"

module JulewireCapture
  def reset_julewire!
    Julewire.reset!
  end

  def capture_records
    Julewire::Testing.capture
  end
end
