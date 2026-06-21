# frozen_string_literal: true

module Julewire
  module Rack
    module Capture
      module BodyContentType
        JSON_ONLY = ["application/json", %r{\Aapplication/.+\+json\z}].freeze
        BINARY_MEDIA_TYPES = %w[
          application/gzip
          application/octet-stream
          application/pdf
          application/x-gzip
          application/zip
        ].freeze
        BINARY_MEDIA_PREFIXES = %w[
          audio/
          font/
          image/
          video/
        ].freeze

        class << self
          def allowed?(target, selector:)
            media_type = media_type_for(target)
            return false if binary?(media_type)
            return true if selector == true
            return false unless selector

            return false if media_type.empty?

            Array(selector).any? { matches?(media_type, it) }
          end

          def binary?(media_type)
            value = media_type.to_s
            return true if BINARY_MEDIA_TYPES.include?(value)

            BINARY_MEDIA_PREFIXES.any? { value.start_with?(it) }
          end

          def media_type_for(target)
            normalized_media_type(raw_content_type(target))
          end

          def raw_content_type(target)
            direct_content_type(target) || header_content_type(target)
          rescue StandardError
            nil
          end

          def direct_content_type(target)
            return target.media_type if target.respond_to?(:media_type)
            return target.content_mime_type.to_s if target.respond_to?(:content_mime_type) && target.content_mime_type
            return target.content_type if target.respond_to?(:content_type)

            target.get_header("CONTENT_TYPE") if target.respond_to?(:get_header)
          end

          def header_content_type(target)
            header_value(target.headers, "content-type") if target.respond_to?(:headers)
          end

          def header_value(headers, key)
            return unless headers.respond_to?(:[])

            headers[key] || headers[key.upcase] || headers[key.split("-").map(&:capitalize).join("-")]
          end

          def matches?(media_type, matcher)
            case matcher
            when Regexp
              matcher.match?(media_type)
            else
              media_type == normalized_media_type(matcher)
            end
          end

          def normalized_media_type(value)
            value.to_s.partition(";").first.strip.downcase
          end
        end
      end
    end
  end
end
