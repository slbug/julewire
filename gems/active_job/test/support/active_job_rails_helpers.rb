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
  end
end
