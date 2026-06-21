# frozen_string_literal: true

module Julewire
  module ActiveJobRailsHelpers
    def with_fake_rails_event(event, &)
      if Object.const_defined?(:Rails)
        with_overridden_singleton_method(Rails, :event, proc { event }, &)
      else
        Object.const_set(:Rails, Module.new)
        Rails.define_singleton_method(:event) { event }
        yield
      end
    ensure
      if defined?(Rails) && Rails.singleton_methods.include?(:event) && !defined?(::Rails::Railtie)
        Object.__send__(:remove_const, :Rails)
      end
    end

    def with_fake_event_reporter_log_subscriber
      previous = if ::ActiveSupport.const_defined?(:EventReporter, false)
                   ::ActiveSupport.const_get(:EventReporter, false)
                 end
      ::ActiveSupport.send(:remove_const, :EventReporter) if ::ActiveSupport.const_defined?(:EventReporter, false)
      event_reporter = Module.new
      log_subscriber = Class.new
      event_reporter.const_set(:LogSubscriber, log_subscriber)
      ::ActiveSupport.const_set(:EventReporter, event_reporter)
      yield log_subscriber
    ensure
      ::ActiveSupport.send(:remove_const, :EventReporter) if ::ActiveSupport.const_defined?(:EventReporter, false)
      ::ActiveSupport.const_set(:EventReporter, previous) if previous
    end

    def with_fake_rails_railtie
      state = capture_rails_railtie_state
      base = Class.new(ActiveJobFixtures::FakeBase)
      loads = []

      install_fake_rails_railtie

      yield loads, base
    ensure
      restore_rails_railtie_state(state)
    end

    def capture_rails_railtie_state
      rails = Object.const_get(:Rails) if Object.const_defined?(:Rails)
      {
        rails: rails,
        railtie_autoload: Julewire::ActiveJob.autoload?(:Railtie),
        railtie: current_active_job_railtie
      }
    end

    def current_active_job_railtie
      return if Julewire::ActiveJob.autoload?(:Railtie)
      return unless Julewire::ActiveJob.const_defined?(:Railtie, false)

      Julewire::ActiveJob.const_get(:Railtie, false)
    end

    def install_fake_rails_railtie
      Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails)
      Module.new.tap do |rails_module|
        rails_module.const_set(:Railtie, fake_railtie_class)
        Object.const_set(:Rails, rails_module)
      end
      Julewire::ActiveJob.send(:remove_const, :Railtie) if Julewire::ActiveJob.const_defined?(:Railtie, false)
    end

    def fake_railtie_class
      Class.new do
        class << self
          def config = @config ||= Struct.new(:julewire_active_job).new

          def initializers = @initializers ||= []

          def initializer(_name, &block) = initializers << block
        end
      end
    end

    def restore_rails_railtie_state(state)
      Julewire::ActiveJob.send(:remove_const, :Railtie) if Julewire::ActiveJob.const_defined?(:Railtie, false)
      Julewire::ActiveJob.const_set(:Railtie, state[:railtie]) if state[:railtie]
      Julewire::ActiveJob.autoload(:Railtie, state[:railtie_autoload]) if state[:railtie_autoload]
      Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails)
      Object.const_set(:Rails, state[:rails]) if state[:rails]
    end
  end
end
