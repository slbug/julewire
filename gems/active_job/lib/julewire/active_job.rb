# frozen_string_literal: true

require "zeitwerk"
require "julewire/core"
require "julewire/rails_support"

module Julewire
  module ActiveJob
    class Error < Julewire::Error; end
    CARRIER_IVAR = :@julewire_carrier
    IntegrationHealth = Core::Integration::Health.scoped(:active_job)
    private_constant :CARRIER_IVAR

    extend Core::Integration::Configurable

    configurable_with { Configuration }

    class << self
      def install!(base: nil, event_reporter: nil, configuration: config)
        Installer.install!(base: base, event_reporter: event_reporter, configuration: configuration)
      end

      def perform(job, &)
        JobExecution.call(job, configuration: config, &)
      end

      def load_railtie_if_rails!
        Railtie if defined?(::Rails::Railtie)
      end
    end
  end

  loader = Zeitwerk::Loader.for_gem_extension(self)
  # Rails-only autoload, skipped when non-Rails processes eager load the gem.
  loader.do_not_eager_load("#{__dir__}/active_job/railtie.rb")
  loader.setup
  Julewire::ActiveJob.load_railtie_if_rails!
end
