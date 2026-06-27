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

    def emit_active_job_event(name:, payload:, configuration: Julewire::ActiveJob::Configuration.new)
      subscriber = Julewire::ActiveJob::Subscribers::Event.new

      Julewire::ActiveJob::JobExecution.call(fake_job, configuration:) do
        subscriber.emit(name:, payload:)
      end
    end
  end
end
