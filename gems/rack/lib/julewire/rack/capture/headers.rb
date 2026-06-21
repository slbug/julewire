# frozen_string_literal: true

module Julewire
  module Rack
    module Capture
      module Headers
        class << self
          def request(request, selector:)
            env = request.env if request.respond_to?(:env)
            return {} unless env.respond_to?(:each)

            selection = HeaderSelection.build(selector)
            return {} unless selection

            capture_headers(env, selection) { request_header_name(it) }
          end

          def response(headers, selector:)
            return {} unless headers.respond_to?(:each)

            selection = HeaderSelection.build(selector)
            return {} unless selection

            capture_headers(headers, selection) { HeaderSelection.normalize_name(it) }
          end

          private

          def capture_headers(headers, selection)
            captured = {}
            headers.each do |key, value|
              name = yield key
              next unless name && selection.include?(name)

              captured[name] = header_value(value)
            end
            captured
          end

          def request_header_name(key)
            name = key.to_s
            return "content-type" if name == "CONTENT_TYPE"
            return "content-length" if name == "CONTENT_LENGTH"
            return unless name.start_with?("HTTP_")

            HeaderSelection.normalize_name(name.delete_prefix("HTTP_"))
          end

          def header_value(value)
            return value.join(", ") if value.is_a?(Array)

            value.to_s
          end
        end
      end
    end
  end
end
