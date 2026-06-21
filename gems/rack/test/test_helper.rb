# frozen_string_literal: true

require "julewire/core/testing/coverage"
Julewire::Core::Testing::Coverage.start!

require "julewire/rack"
require "minitest/autorun"
require "julewire/core/testing/test_reports"
Julewire::Core::Testing::TestReports.start!
require "mutant/minitest/coverage"
