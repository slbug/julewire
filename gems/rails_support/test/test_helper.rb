# frozen_string_literal: true

require_relative "../../../support/testing/coverage"
Julewire::TestSupport::Coverage.start!

require "julewire/rails_support"
require "minitest/autorun"
require "minitest/strict"
require_relative "../../../support/testing/test_reports"
Julewire::TestSupport::TestReports.start!
require_relative "../../../support/mutant/minitest_coverage"
