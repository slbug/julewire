# frozen_string_literal: true

require "active_support/notifications"

module Julewire
  module Rails
    module Subscribers
      class ControllerResponse
        EVENT_NAME = "process_action.action_controller"

        class << self
          include Core::Integration::SubscriberInstall

          def install!(configuration)
            return reset! unless configuration.controller_capture?

            install_subscriber(configuration, enabled: true) do |subscriber|
              subscription = ::ActiveSupport::Notifications.subscribe(EVENT_NAME) do |*arguments|
                subscriber.process_action(::ActiveSupport::Notifications::Event.new(*arguments))
              end
              -> { ::ActiveSupport::Notifications.unsubscribe(subscription) }
            end
          end
        end

        def initialize(configuration = Configuration.new)
          @configuration = configuration
        end

        attr_writer :configuration

        def process_action(event)
          return unless Julewire.current_execution?
          return if Suppression.active?

          IntegrationHealth.with_failure_health(action: :process_action, component: :controller_response_subscriber) do
            fields = capture_attributes(event.payload)
            Core::Integration::Facade.add_summary_attributes(fields[:attributes])
            Core::Integration::Facade.add_summary_neutral(fields[:neutral])
          end
        end

        private

        def capture_attributes(payload)
          rails_fields = capture_fields(payload)
          neutral = {}
          response_body_bytes = rails_fields[:response_body_bytes]
          if response_body_bytes
            neutral = {
              Core::Fields::AttributeKeys::HTTP_RESPONSE_BODY_SIZE => response_body_bytes
            }
          end
          { attributes: { rails: rails_fields }, neutral: neutral }
        end

        def capture_fields(payload)
          fields = {}
          merge_capture_fields(fields, request_headers_fields(payload))
          merge_capture_fields(
            fields,
            body_fields_for(:request, payload[:request], Julewire::Rack::Capture::RequestBody)
          )
          merge_capture_fields(fields, response_headers_fields(payload))
          merge_capture_fields(
            fields,
            body_fields_for(:response, payload[:response], Julewire::Rack::Capture::BufferedResponseBody)
          )
          fields
        end

        def request_headers_fields(payload)
          return unless @configuration.request_capture.headers?

          capture_headers(:request_headers) do
            Julewire::Rack::Capture::Headers.request(
              payload[:request],
              selector: @configuration.request_capture.headers
            )
          end
        end

        def response_headers_fields(payload)
          response = payload[:response]
          return unless @configuration.response_capture.headers? && response

          capture_headers(:response_headers) do
            Julewire::Rack::Capture::Headers.response(
              response.headers,
              selector: @configuration.response_capture.headers
            )
          end
        end

        def body_fields_for(type, target, capture)
          capture_configuration = @configuration.public_send("#{type}_capture")
          return unless capture_configuration.body?

          capture.call(
            target,
            content_types: capture_configuration.body_content_types,
            limit: capture_configuration.body_bytes,
            mode: capture_configuration.body_mode
          )
        end

        def capture_headers(key)
          headers = yield
          headers.empty? ? nil : { key => headers }
        end

        def merge_capture_fields(fields, captured)
          fields.merge!(captured) if captured && !captured.empty?
        end
      end
    end
  end
end
