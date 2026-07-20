# frozen_string_literal: true

require "support/active_job_test_support"

module Julewire
  class TestActiveJobLogSubscriberSilencer < Minitest::Test
    cover Julewire::ActiveJob::LogSubscriberSilencer
    include ActiveJobTestSupport

    def test_log_subscriber_silencer_delegates_real_subscriber_with_symbol_namespace
      Julewire::Core::Integration::Lifecycle.require_optional("active_job/log_subscriber")
      required = []
      detached = []
      shadow_log_subscribers = Module.new do
        def self.detach(_subscriber_class, _namespace) = raise "nested RailsSupport must not be used"
      end
      shadow_rails_support = Module.new
      shadow_rails_support.const_set(:LogSubscribers, shadow_log_subscribers)
      Julewire::ActiveJob.const_set(:RailsSupport, shadow_rails_support)

      begin
        with_overridden_singleton_method(
          Julewire::Core::Integration::Lifecycle,
          :require_optional,
          proc { |path| required << path }
        ) do
          with_overridden_singleton_method(
            Julewire::RailsSupport::LogSubscribers,
            :detach,
            proc { |subscriber_class, namespace| detached << [subscriber_class, namespace] }
          ) do
            Julewire::ActiveJob::LogSubscriberSilencer.silence!
          end
        end
      ensure
        Julewire::ActiveJob.__send__(:remove_const, :RailsSupport)
      end

      assert_equal ["active_job/log_subscriber"], required
      assert_equal [[::ActiveJob::LogSubscriber, :active_job]], detached
    end

    def test_log_subscriber_path_resolves_against_current_active_job
      refute_nil Julewire::Core::Integration::Lifecycle.require_optional("active_job/log_subscriber")
    end

    def test_log_subscriber_silencer_is_a_noop_when_subscriber_is_absent
      previous = ::ActiveJob.const_get(:LogSubscriber, false) if ::ActiveJob.const_defined?(:LogSubscriber, false)
      ::ActiveJob.send(:remove_const, :LogSubscriber) if ::ActiveJob.const_defined?(:LogSubscriber, false)

      with_overridden_singleton_method(
        Julewire::Core::Integration::Lifecycle,
        :require_optional,
        proc { |_path| }
      ) do
        assert_nil Julewire::ActiveJob::LogSubscriberSilencer.silence!
      end
    ensure
      ::ActiveJob.const_set(:LogSubscriber, previous) if defined?(previous) && previous
    end
  end
end
