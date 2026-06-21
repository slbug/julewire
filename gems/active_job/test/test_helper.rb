# frozen_string_literal: true

require "julewire/core/testing/coverage"
Julewire::Core::Testing::Coverage.start!

require "julewire/active_job"
require "julewire/core/testing"
require "minitest/autorun"
require "julewire/core/testing/test_reports"
Julewire::Core::Testing::TestReports.start!
require "mutant/minitest/coverage"

module JulewireCapture
  include Julewire::Core::Testing::Contracts

  def reset_julewire!
    Julewire.reset!
  end

  def capture_records
    Julewire::Core::Testing.capture
  end
end
