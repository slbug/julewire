# frozen_string_literal: true

module Julewire
  module Rack
    module Capture
      class HeaderSelection
        SENSITIVE_HEADERS = %w[
          authorization
          cookie
          proxy-authorization
          set-cookie
          x-api-key
        ].freeze
        SENSITIVE_HEADER_SET = SENSITIVE_HEADERS.to_h { [it, true] }.freeze

        class << self
          def build(selector)
            return unless selector

            allowed = Array(selector).to_h { [normalize_name(it), true] } unless selector == true
            new(allowed)
          end

          def normalize_name(name) = name.to_s.tr("_", "-").downcase
        end

        def initialize(allowed)
          @allowed = allowed
        end

        def include?(name)
          @allowed ? @allowed.key?(name) : !SENSITIVE_HEADER_SET.key?(name)
        end
      end
    end
  end
end
