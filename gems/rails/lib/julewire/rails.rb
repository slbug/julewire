# frozen_string_literal: true

require "zeitwerk"
require "julewire/core"
require "julewire/rack"
require "julewire/rails_support"
require "rails"

module Julewire
  module Rails
    class Error < Julewire::Error; end
    IntegrationHealth = Core::Integration::Health.scoped(:rails)

    class << self
      def config
        application = ::Rails.application
        raise Error, "Rails.application is not available" unless application

        application.config.julewire_rails
      end

      def configure
        raise ArgumentError, "Julewire::Rails.configure requires a block" unless block_given?

        yield config
        config
      end
    end
  end

  loader = Zeitwerk::Loader.for_gem_extension(self)
  loader.setup
  Core::Processing.register(:rails_parameter_filter) do |*args, **options|
    Rails::ParameterFilterProcessor.new(*args, **options)
  end
  Julewire::Rails::Railtie
end
