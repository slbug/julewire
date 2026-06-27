# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestSubscriberInstall < Minitest::Test
    cover Julewire::Rails::Subscribers
    cover "Julewire::Rails::Railtie.install_subscribers"
    cover Julewire::Rails::LogSubscriberSilencer
    def test_railtie_subscriber_installer_resets_disabled_subscribers
      settings = Julewire::Rails::Configuration.new
      settings.error_reports = false
      settings.request_summary = false
      settings.structured_events = false
      calls = []

      with_captured_subscriber_install(calls) do
        Julewire::Rails::Railtie.install_subscribers(settings)
      end

      assert_equal [
        %i[controller_response install],
        %i[error reset],
        %i[rendered_exception install],
        %i[event reset]
      ], calls
    end

    def test_railtie_subscriber_installer_installs_enabled_subscribers_and_silences
      settings = Julewire::Rails::Configuration.new
      settings.error_reports = true
      settings.structured_events = true
      settings.silence_log_subscribers = true
      calls = []

      with_enabled_subscriber_install(calls) do
        Julewire::Rails::Railtie.install_subscribers(settings)
      end

      assert_equal [
        %i[controller_response install],
        %i[error install],
        %i[rendered_exception install],
        %i[event install],
        %i[log_subscribers silence]
      ], calls
    end

    def test_railtie_subscriber_installer_keeps_log_subscribers_when_silencing_disabled
      settings = Julewire::Rails::Configuration.new
      settings.error_reports = true
      settings.structured_events = true
      settings.silence_log_subscribers = false
      calls = []

      with_enabled_subscriber_install(calls) do
        Julewire::Rails::Railtie.install_subscribers(settings)
      end

      assert_equal [
        %i[controller_response install],
        %i[error install],
        %i[rendered_exception install],
        %i[event install]
      ], calls
    end

    private

    def with_captured_subscriber_install(calls, &)
      with_overridden_singleton_method(
        Julewire::Rails::Subscribers::ControllerResponse,
        :install!,
        proc { |_settings| calls << %i[controller_response install] }
      ) do
        capture_subscriber_install_and_reset(calls, Julewire::Rails::Subscribers::Error, :error) do
          capture_subscriber_install_and_reset(calls, Julewire::Rails::Subscribers::RenderedException,
                                               :rendered_exception) do
            capture_subscriber_install_and_reset(calls, Julewire::Rails::Subscribers::Event, :event, &)
          end
        end
      end
    end

    def capture_subscriber_install_and_reset(calls, subscriber, component, &)
      with_overridden_singleton_method(
        subscriber,
        :install!,
        proc { |_settings| calls << [component, :install] }
      ) do
        with_overridden_singleton_method(
          subscriber,
          :reset!,
          proc { calls << [component, :reset] },
          &
        )
      end
    end

    def with_enabled_subscriber_install(calls, &)
      capture_subscriber_install(calls, Julewire::Rails::Subscribers::ControllerResponse, :controller_response) do
        capture_subscriber_install(calls, Julewire::Rails::Subscribers::Error, :error) do
          capture_subscriber_install(calls, Julewire::Rails::Subscribers::RenderedException, :rendered_exception) do
            capture_subscriber_install(calls, Julewire::Rails::Subscribers::Event, :event) do
              with_overridden_singleton_method(
                Julewire::Rails::LogSubscriberSilencer,
                :silence!,
                proc { calls << %i[log_subscribers silence] },
                &
              )
            end
          end
        end
      end
    end

    def capture_subscriber_install(calls, subscriber, component, &)
      with_overridden_singleton_method(
        subscriber,
        :install!,
        proc { |_settings| calls << [component, :install] },
        &
      )
    end
  end
end
