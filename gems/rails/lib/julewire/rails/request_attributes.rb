# frozen_string_literal: true

module Julewire
  module Rails
    module RequestAttributes
      class << self
        def context_fields(request)
          request = request_fields(request)
          values = Core::Integration::Values::Shape
          {}.tap do |fields|
            values.append_field(fields, :request_id, request.id)
            values.append_field(fields, :http_method, request.request_method)
            values.append_field(fields, :path, request.path)
            values.append_field(fields, :remote_ip, request.remote_ip)
          end
        end

        def request(request)
          request_neutral_attributes(request)
        end

        def response_summary(request, status, headers)
          {
            attributes: { rails: rails_response_attributes(request, status, headers) },
            neutral: neutral_fields(Core::Fields::AttributeKeys::HTTP_RESPONSE_STATUS_CODE => status)
          }
        end

        def rendered_error_details(rendered_error)
          apply_rendered_error_metadata(error_details(rendered_error.fetch(:error), wrapper: nil), rendered_error)
        end

        def error_summary(request, error, status:, wrapper:)
          {
            attributes: { rails: rails_error_attributes(request, error, status: status, wrapper: wrapper) },
            neutral: neutral_fields(Core::Fields::AttributeKeys::HTTP_RESPONSE_STATUS_CODE => status)
          }
        end

        def error_details(error, wrapper:)
          {
            attributes: { rails: rails_exception_attributes(error, wrapper: wrapper) },
            neutral: {}
          }
        end

        def request_id(request)
          request_fields(request).id
        end

        # Rack headers and parsed bodies are user input. Normalize them before
        # passing adapter-owned records to the core integration boundary.
        def normalize_user_fields(fields)
          Core::Fields::FieldSet.deep_symbolize_keys(fields)
        end

        private

        def request_neutral_attributes(request)
          request = request_fields(request)
          values = Core::Integration::Values::Shape
          fields = {}
          values.append_field(
            fields,
            Core::Fields::AttributeKeys::HTTP_REQUEST_METHOD,
            request.request_method
          )
          values.append_field(fields, Core::Fields::AttributeKeys::URL_FULL, request.filtered_url)
          values.append_field(fields, Core::Fields::AttributeKeys::URL_PATH, request.path)
          values.append_field(
            fields,
            Core::Fields::AttributeKeys::USER_AGENT_ORIGINAL,
            request.user_agent
          )
          values.append_field(fields, Core::Fields::AttributeKeys::CLIENT_ADDRESS, request.remote_ip)
          fields
        end

        def rails_response_attributes(request, status, headers)
          rails_request_attributes(request).tap do |rails|
            values = Core::Integration::Values::Shape
            values.append_field(rails, :status, status)
            values.append_field(rails, :response_content_type, response_header(headers, "content-type"))
          end
        end

        def rails_error_attributes(request, error, status:, wrapper:)
          rails_request_attributes(request).tap do |rails|
            values = Core::Integration::Values::Shape
            values.append_field(rails, :status, status)
            rails_exception_attributes(error, wrapper: wrapper).each do |key, value|
              values.append_field(rails, key, value)
            end
          end
        end

        def rails_exception_attributes(error, wrapper:)
          values = Core::Integration::Values::Shape
          {}.tap do |fields|
            values.append_field(fields, :error_class, error.class.name)
            values.append_field(fields, :rescue_response, rescue_response?(wrapper))
            values.append_field(fields, :rescue_template, rescue_template(wrapper))
          end
        end

        def apply_rendered_error_metadata(fields, rendered_error)
          rails = fields.fetch(:attributes).fetch(:rails)
          rails[:rescue_response] = rendered_error[:rescue_response]
          rails[:rescue_template] = rendered_error[:rescue_template]
          fields
        end

        def rails_request_attributes(request)
          request = request_fields(request)
          values = Core::Integration::Values::Shape
          {}.tap do |fields|
            values.append_field(fields, :filtered_url, request.filtered_url)
            values.append_field(fields, :filtered_path, request.filtered_path)
            values.append_field(fields, :request_method, request.request_method)
            values.append_field(fields, :path, request.path)
            values.append_field(fields, :user_agent, request.user_agent)
          end
        end

        def rescue_response?(wrapper)
          wrapper.rescue_response?
        rescue StandardError
          false
        end

        def rescue_template(wrapper)
          wrapper.rescue_template
        rescue StandardError
          nil
        end

        def response_header(headers, key)
          Julewire::Rack::Capture::BodyContentType.header_value(headers, key)
        end

        def request_fields(request) = RequestFields.new(request)

        def neutral_fields(fields) = Core::Fields::AttributeKeys.fields(fields)
      end
    end
  end
end
