# frozen_string_literal: true

require "test_helper"
require "active_job"
require "support/active_job_fixtures"
require "support/active_job_helpers"
require "support/active_job_rails_helpers"

module Julewire
  module ActiveJobTestSupport
    include JulewireCapture
    include ActiveJobFixtures
    include ActiveJobHelpers
    include ActiveJobRailsHelpers

    def setup
      reset_julewire!
      Julewire::ActiveJob.reset!
    end
  end
end
