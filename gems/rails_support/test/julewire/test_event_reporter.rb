# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRailsSupportEventReporter < Minitest::Test
    cover Julewire::RailsSupport::EventReporter

    def test_unsubscriber_uses_reporter_unsubscribe_when_available
      reporter = Object.new
      subscriber = Object.new
      unsubscribed = []
      reporter.define_singleton_method(:unsubscribe) { unsubscribed << it }

      Julewire::RailsSupport::EventReporter.unsubscriber(reporter, subscriber).call

      assert_equal [subscriber], unsubscribed
    end

    def test_unsubscriber_ignores_reporters_without_unsubscribe
      subscriber = Object.new

      assert_nil Julewire::RailsSupport::EventReporter.unsubscriber(Object.new, subscriber).call
    end

    def test_subscribe_registers_subscriber_and_returns_unsubscriber
      reporter = Object.new
      subscriber = Object.new
      subscriptions = []
      unsubscriptions = []
      reporter.define_singleton_method(:subscribe) { |value, &filter| subscriptions << [value, filter.call(:payload)] }
      reporter.define_singleton_method(:unsubscribe) { unsubscriptions << it }

      unsubscribe = Julewire::RailsSupport::EventReporter.subscribe(reporter, subscriber) { it == :payload }
      unsubscribe.call

      assert_equal [[subscriber, true]], subscriptions
      assert_equal [subscriber], unsubscriptions
    end

    def test_subscribe_ignores_reporters_without_subscribe
      refute Julewire::RailsSupport::EventReporter.subscribable?(Object.new)
      assert_nil Julewire::RailsSupport::EventReporter.subscribe(Object.new, Object.new)
    end

    def test_default_prefers_rails_event_reporter
      assert_default_reporter_from_constant(:Rails, :event)
    end

    def test_default_reads_top_level_rails_event_reporter
      assert_default_reads_top_level_constant(:Rails, :event)
    end

    def test_default_falls_back_to_active_support_event_reporter
      assert_default_reporter_from_constant(:ActiveSupport, :event_reporter)
    end

    def test_default_reads_top_level_active_support_event_reporter
      assert_default_reads_top_level_constant(:ActiveSupport, :event_reporter)
    end

    def test_default_uses_active_support_when_rails_has_no_event_reporter
      reporter = Object.new
      rails = Module.new
      active_support = module_with_singleton_value(:event_reporter, reporter)

      with_object_constant(:Rails, rails) do
        with_object_constant(:ActiveSupport, active_support) do
          assert_same reporter, Julewire::RailsSupport::EventReporter.default
        end
      end
    end

    def test_default_ignores_active_support_without_event_reporter
      with_object_constant(:ActiveSupport, Module.new) do
        assert_nil Julewire::RailsSupport::EventReporter.default
      end
    end

    def test_default_ignores_kernel_inherited_constants
      reporter = Object.new
      rails = module_with_singleton_value(:event, reporter)

      with_nested_constant(Kernel, :Rails, rails) do
        assert_nil Julewire::RailsSupport::EventReporter.default
      end
    end

    def test_unsubscribe_log_subscriber_removes_active_support_log_subscriber
      reporter = Object.new
      unsubscribed = []
      reporter.define_singleton_method(:unsubscribe) { unsubscribed << it }
      subscriber_class = nil
      active_support = active_support_with_log_subscriber do |log_subscriber|
        subscriber_class = Class.new(log_subscriber)
      end

      with_object_constant(:ActiveSupport, active_support) do
        Julewire::RailsSupport::EventReporter.unsubscribe_log_subscriber(subscriber_class, reporter: reporter)
      end

      assert_equal [subscriber_class], unsubscribed
    end

    def test_unsubscribe_log_subscriber_uses_default_reporter
      reporter = Object.new
      unsubscribed = []
      reporter.define_singleton_method(:unsubscribe) { unsubscribed << it }
      subscriber_class = nil
      active_support = active_support_with_log_subscriber do |log_subscriber|
        subscriber_class = Class.new(log_subscriber)
      end
      active_support.define_singleton_method(:event_reporter) { reporter }

      with_object_constant(:ActiveSupport, active_support) do
        Julewire::RailsSupport::EventReporter.unsubscribe_log_subscriber(subscriber_class)
      end

      assert_equal [subscriber_class], unsubscribed
    end

    def test_unsubscribe_log_subscriber_ignores_non_log_subscribers
      reporter = Object.new
      unsubscribed = []
      reporter.define_singleton_method(:unsubscribe) { unsubscribed << it }
      active_support = active_support_with_log_subscriber

      with_object_constant(:ActiveSupport, active_support) do
        Julewire::RailsSupport::EventReporter.unsubscribe_log_subscriber(Object, reporter: reporter)
      end

      assert_empty unsubscribed
    end

    def test_unsubscribe_log_subscriber_ignores_non_reporters
      assert_nil Julewire::RailsSupport::EventReporter.unsubscribe_log_subscriber(Object)
    end

    def test_unsubscribe_log_subscriber_ignores_reporter_without_unsubscribe_for_log_subscriber
      subscriber_class = nil
      active_support = active_support_with_log_subscriber do |log_subscriber|
        subscriber_class = Class.new(log_subscriber)
      end

      with_object_constant(:ActiveSupport, active_support) do
        result = Julewire::RailsSupport::EventReporter.unsubscribe_log_subscriber(
          subscriber_class,
          reporter: Object.new
        )

        assert_nil result
      end
    end

    def test_unsubscribe_log_subscriber_ignores_subscriber_comparison_errors
      reporter = Object.new
      unsubscribed = []
      reporter.define_singleton_method(:unsubscribe) { unsubscribed << it }
      bad_subscriber = Object.new
      bad_subscriber.define_singleton_method(:<) { raise "comparison failed" }
      active_support = active_support_with_log_subscriber

      with_object_constant(:ActiveSupport, active_support) do
        assert_nil Julewire::RailsSupport::EventReporter.unsubscribe_log_subscriber(bad_subscriber, reporter: reporter)
      end

      assert_empty unsubscribed
    end

    def test_unsubscribe_log_subscriber_ignores_inherited_event_reporter_constant
      reporter = Object.new
      unsubscribed = []
      reporter.define_singleton_method(:unsubscribe) { unsubscribed << it }
      log_subscriber = Class.new
      event_reporter = Module.new
      event_reporter.const_set(:LogSubscriber, log_subscriber)
      parent = Class.new
      parent.const_set(:EventReporter, event_reporter)
      active_support = Class.new(parent)
      subscriber = Class.new(log_subscriber)

      with_object_constant(:ActiveSupport, active_support) do
        assert_nil Julewire::RailsSupport::EventReporter.unsubscribe_log_subscriber(subscriber, reporter: reporter)
      end

      assert_empty unsubscribed
    end

    def test_unsubscribe_log_subscriber_ignores_inherited_log_subscriber_constant
      reporter = Object.new
      unsubscribed = []
      reporter.define_singleton_method(:unsubscribe) { unsubscribed << it }
      log_subscriber = Class.new
      event_reporter_parent = Class.new
      event_reporter_parent.const_set(:LogSubscriber, log_subscriber)
      event_reporter = Class.new(event_reporter_parent)
      active_support = Module.new
      active_support.const_set(:EventReporter, event_reporter)
      subscriber = Class.new(log_subscriber)

      with_object_constant(:ActiveSupport, active_support) do
        assert_nil Julewire::RailsSupport::EventReporter.unsubscribe_log_subscriber(subscriber, reporter: reporter)
      end

      assert_empty unsubscribed
    end

    private

    def assert_default_reporter_from_constant(constant_name, method_name)
      reporter = Object.new
      value = module_with_singleton_value(method_name, reporter)

      with_object_constant(constant_name, value) do
        assert_same reporter, Julewire::RailsSupport::EventReporter.default
      end
    end

    def assert_default_reads_top_level_constant(constant_name, method_name)
      reporter = Object.new
      nested_shadow = module_with_singleton_value(method_name, Object.new)
      namespace_shadow = Module.new
      top_level = module_with_singleton_value(method_name, reporter)

      with_nested_constant(Julewire::RailsSupport::EventReporter, constant_name, nested_shadow) do
        with_nested_constant(Julewire, constant_name, namespace_shadow) do
          with_object_constant(constant_name, top_level) do
            assert_same reporter, Julewire::RailsSupport::EventReporter.default
          end
        end
      end
    end

    def module_with_singleton_value(method_name, value)
      Module.new.tap do |mod|
        mod.define_singleton_method(method_name) do
          value
        end
      end
    end

    def active_support_with_log_subscriber
      log_subscriber = Class.new
      event_reporter = Module.new
      event_reporter.const_set(:LogSubscriber, log_subscriber)
      active_support = Module.new
      active_support.const_set(:EventReporter, event_reporter)
      yield log_subscriber if block_given?
      active_support
    end

    def with_object_constant(name, value, &)
      with_nested_constant(Object, name, value, &)
    end

    def with_nested_constant(parent, name, value)
      had_constant = parent.const_defined?(name, false)
      previous = parent.const_get(name, false) if had_constant
      parent.__send__(:remove_const, name) if had_constant
      parent.const_set(name, value)
      yield
    ensure
      parent.__send__(:remove_const, name) if parent.const_defined?(name, false)
      parent.const_set(name, previous) if had_constant
    end
  end
end
