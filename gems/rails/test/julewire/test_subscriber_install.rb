# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestSubscriberInstall < Minitest::Test
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
        %i[rendered_exception reset],
        %i[event reset]
      ], calls
    end

    private

    def with_overridden_singleton_method(...)
      Julewire::Core::Testing.with_overridden_singleton_method(...)
    end

    def with_captured_subscriber_install(calls, &)
      with_overridden_singleton_method(
        Julewire::Rails::Subscribers::ControllerResponse,
        :install!,
        proc { |_settings| calls << %i[controller_response install] }
      ) do
        capture_subscriber_reset(calls, Julewire::Rails::Subscribers::Error, :error) do
          capture_subscriber_reset(calls, Julewire::Rails::Subscribers::RenderedException, :rendered_exception) do
            capture_subscriber_reset(calls, Julewire::Rails::Subscribers::Event, :event, &)
          end
        end
      end
    end

    def capture_subscriber_reset(calls, subscriber, component, &)
      with_overridden_singleton_method(
        subscriber,
        :reset!,
        proc { calls << [component, :reset] },
        &
      )
    end
  end
end
