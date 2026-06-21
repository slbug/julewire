# frozen_string_literal: true

module Julewire
  module Redaction
    class Configuration
      include Julewire::Core::Integration::Settings

      setting :authorization_header, default: true
      setting :filters, default: DEFAULT_FILTERS
      setting :mask, default: DEFAULT_MASK
      setting :max_array_items, default: Julewire::Serializer::DEFAULT_MAX_ARRAY_ITEMS,
                                validate: integer_limit
      setting :max_depth, default: Julewire::Serializer::DEFAULT_MAX_DEPTH,
                          validate: integer_limit(positive: true)
      setting :max_hash_keys, default: Julewire::Serializer::DEFAULT_MAX_HASH_KEYS,
                              validate: integer_limit
      setting :max_string_bytes, default: Julewire::Serializer::DEFAULT_MAX_STRING_BYTES,
                                 validate: integer_limit
      setting :string_values, default: false
    end
  end
end
