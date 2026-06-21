# frozen_string_literal: true

module Julewire
  module ActiveJob
    class Railtie < ::Rails::Railtie
      config.julewire_active_job = Julewire::ActiveJob.config

      initializer "julewire.active_job" do |app|
        Julewire::ActiveJob::Railtie.install_active_job!(app.config.julewire_active_job)
      end

      class << self
        def install_active_job!(settings)
          return unless settings.enabled?

          ActiveSupport.on_load(:active_job) do
            Julewire::ActiveJob.install!(base: self, configuration: settings)
          end
        end
      end
    end
  end
end
