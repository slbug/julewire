# frozen_string_literal: true

module Julewire
  module Ractor
    # Serializes cross-ractor values without changing the internal Symbol-key
    # protocol into a JSON-shaped String-key protocol.
    class RemoteSerializer < Core::Serialization::Serializer
      def serialize(value)
        Core::Integration::Protocol.validate_symbol_keys(value)
        super
      end

      private

      def initialize(**)
        super
        @truncation_key = TRUNCATION_METADATA_KEY.to_sym
      end

      def key_value(key) = super.to_sym

      def truncation_metadata(fields) = super(fields, key_style: :symbol)
    end

    private_constant :RemoteSerializer
  end
end
