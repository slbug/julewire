# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestEventSubscriberFiltering < Minitest::Test
    cover Julewire::Rails::Subscribers::Event

    def test_event_subscriber_defaults_to_useful_framework_events_without_view_chatter
      subscriber = Julewire::Rails::Subscribers::Event.new

      assert_event_filter(
        subscriber,
        accepts: ["action_controller.request_started", "action_dispatch.redirect", "active_record.sql"],
        rejects: ["action_view.render_template", "action_view.render_start"]
      )
    end

    def test_event_subscriber_accepts_configured_prefixes_and_names
      [
        [
          event_subscriber(structured_event_prefixes: ["action_controller."]),
          ["action_controller.request_started"],
          ["active_record.sql"]
        ],
        [
          event_subscriber(structured_event_names: ["action_view.render_template"]),
          ["action_view.render_template"],
          ["action_view.render_start"]
        ]
      ].each do |subscriber, accepts, rejects|
        assert_event_filter(subscriber, accepts: accepts, rejects: rejects)
      end
    end

    def test_event_subscriber_excludes_configured_names_and_prefixes
      subscriber = event_subscriber(
        structured_event_prefixes: nil,
        structured_event_exclude_names: ["active_record.sql"],
        structured_event_exclude_prefixes: ["action_view."]
      )

      assert_event_filter(
        subscriber,
        accepts: ["custom.event"],
        rejects: ["active_record.sql", "action_view.render_template"]
      )
    end

    def test_event_subscriber_caches_payload_filter_until_subscriber_configuration_changes
      output = configure_output
      subscriber = Julewire::Rails::Subscribers::Event.new
      filters = [:access_token]
      first_payload = Object.new
      first_payload.define_singleton_method(:serialize) { { access_token: "secret" } }
      second_payload = Object.new
      second_payload.define_singleton_method(:serialize) { { password: "secret" } }

      with_fake_rails_application_filter_parameters(filters) do
        subscriber.emit(name: "custom.first", payload: first_payload)
        filters.replace([:password])
        subscriber.emit(name: "custom.second", payload: second_payload)
        subscriber.configuration = Julewire::Rails::Configuration.new
        subscriber.emit(name: "custom.third", payload: second_payload)
      end

      first, second, third = parse_records(output)

      assert_equal "[FILTERED]", first.dig("attributes", "rails", "access_token")
      assert_equal "secret", second.dig("attributes", "rails", "password")
      assert_equal "[FILTERED]", third.dig("attributes", "rails", "password")
    end

    private

    def assert_event_filter(subscriber, accepts:, rejects:)
      accepts.each { |name| assert subscriber.accept?(name: name), "expected #{name.inspect} to be accepted" }
      rejects.each { |name| refute subscriber.accept?(name: name), "expected #{name.inspect} to be rejected" }
    end

    def event_subscriber(**settings)
      configuration = Julewire::Rails::Configuration.new
      settings.each { |key, value| configuration.public_send("#{key}=", value) }
      Julewire::Rails::Subscribers::Event.new(configuration)
    end
  end
end
