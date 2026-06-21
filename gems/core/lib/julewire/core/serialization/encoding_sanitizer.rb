# frozen_string_literal: true

module Julewire
  module Core
    module Serialization
      module EncodingSanitizer
        class << self
          def call(value)
            raise TypeError, "value must be a String" unless value.is_a?(String)

            return value if valid_utf8?(value) || valid_ascii_only?(value)
            return value.scrub("?") if utf8?(value)

            encode_utf8(value)
          rescue EncodingError
            encode_utf8(value.b.force_encoding(Encoding::UTF_8))
          end

          private

          def valid_utf8?(value)
            utf8?(value) && value.valid_encoding?
          end

          def valid_ascii_only?(value)
            value.ascii_only? && value.valid_encoding?
          end

          def utf8?(value)
            value.encoding == Encoding::UTF_8
          end

          def encode_utf8(value)
            value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
          end
        end
      end
    end
  end
end
