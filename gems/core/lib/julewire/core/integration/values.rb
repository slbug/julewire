# frozen_string_literal: true

require "time"

module Julewire
  module Core
    module Integration
      # @api integration_spi
      module Values
        EMPTY_HASH = {}.freeze

        module Common
          def empty_hash = EMPTY_HASH

          def blank_value?(value)
            value.nil? || (value.respond_to?(:empty?) && value.empty?)
          rescue StandardError
            false
          end
        end

        private_constant :EMPTY_HASH, :Common

        # @api integration_spi
        module Read
          extend Common

          class << self
            def blank?(value)
              blank_value?(value)
            end

            def hash_value(hash, key, default: nil)
              return default unless hash.is_a?(Hash)

              direct_hash_value(hash, key, default)
            end

            def value(object, key, default: nil)
              return hash_value(object, key, default: default) if object.is_a?(Hash)

              return default unless object.respond_to?(key)

              object.public_send(key)
            rescue StandardError
              default
            end

            def nested_value(object, *keys, default: nil)
              current = object
              keys.each do |key|
                return default if current.nil?

                current = value(current, key)
              end
              current.nil? ? default : current
            end

            def path_value(object, path, default: nil)
              current = object
              Array(path).each do |key|
                return default if current.nil?

                current = indexed_value(current, key)
                return default if current.equal?(MISSING)
              end
              current
            end

            def first_value(source, keys:)
              if source.is_a?(Hash)
                found = direct_hash_first_value(source, keys)
                return found unless found.equal?(MISSING)
              end

              keys.each do |key|
                found = indexed_value(source, key)
                return found unless found.equal?(MISSING) || blank_value?(found)
              end
              nil
            end

            private

            def direct_hash_first_value(source, keys)
              keys.each do |key|
                next unless source.key?(key)

                found = source[key]
                return found unless blank_value?(found)
              end
              MISSING
            end

            def indexed_value(source, key)
              return hash_value(source, key, default: MISSING) if source.is_a?(Hash)
              return MISSING unless source.respond_to?(:[])

              source[key]
            rescue StandardError
              MISSING
            end

            def direct_hash_value(hash, key, default)
              return hash[key] if hash.key?(key)

              case key
              when Symbol then symbol_key_value(hash, key, default)
              when String then string_key_value(hash, key, default)
              else default
              end
            end

            def symbol_key_value(hash, key, default)
              string_key = key.name
              return hash[string_key] if hash.key?(string_key)

              default
            end

            def string_key_value(hash, key, default)
              symbol_key = key.to_sym
              return hash[symbol_key] if hash.key?(symbol_key)

              default
            end
          end
        end

        # @api integration_spi
        module Shape
          extend Common

          class << self
            def timestamp(value)
              return unless value
              return value.utc.iso8601(9) if value.respond_to?(:utc) && value.respond_to?(:iso8601)
              return value unless value.respond_to?(:divmod)

              seconds, nanoseconds = value.divmod(1_000_000_000)
              Time.at(seconds, nanoseconds, :nanosecond).utc.iso8601(9)
            rescue StandardError
              nil
            end

            def payload_hash(value)
              case value
              when nil
                empty_hash
              when Hash
                return empty_hash if value.empty?

                Fields::FieldSet.deep_symbolize_keys(value)
              else
                { Fields::FieldSet::VALUE_KEY => value }
              end
            end

            def hash_or_empty(value)
              return empty_hash unless value.is_a?(Hash)
              return empty_hash if value.empty?

              Fields::FieldSet.deep_symbolize_keys(value)
            end

            def append_field(fields, key, value, compact_empty: false)
              return if value.nil?
              return if compact_empty && (value.is_a?(Hash) || value.is_a?(Array)) && value.empty?

              fields[key] = value
              nil
            end

            def append_compact_field(fields, key, value)
              append_field(fields, key, value, compact_empty: true)
            end

            def source_location_attributes(location)
              return {} unless location.is_a?(Hash)

              Fields::AttributeKeys.fields(
                Fields::AttributeKeys::CODE_FILE_PATH => Read.first_value(location, keys: %i[filepath path file]),
                Fields::AttributeKeys::CODE_LINE_NUMBER => Read.first_value(location, keys: %i[lineno line]),
                Fields::AttributeKeys::CODE_FUNCTION_NAME => Read.first_value(location, keys: %i[label function])
              )
            end
          end
        end
      end
    end
  end
end
