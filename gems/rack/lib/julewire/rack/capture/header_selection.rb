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
            return new(true) if selector == true
            return unless selector

            new(Array(selector).to_h { [normalize_name(it), true] })
          end

          def normalize_name(name) = name.to_s.tr("_", "-").downcase
        end

        def initialize(selection)
          @selection = selection
        end

        def include?(name)
          @selection == true ? !SENSITIVE_HEADER_SET.key?(name) : @selection.key?(name)
        end
      end
    end
  end
end
