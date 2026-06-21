# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      class SectionProxy
        STORE_METHODS = Bags.app_write_sections.to_h do |section|
          [
            section,
            {
              add: :"add_#{section}",
              hash: :"#{section}_hash",
              value: :"#{section}_value",
              with: :"with_#{section}"
            }.freeze
          ]
        end.freeze
        private_constant :STORE_METHODS

        def initialize(store, section)
          @store = store
          @section = section
        end

        def add(fields = nil, **keyword_fields)
          add_fields(fields, keyword_fields) { add_section(it) }
        end

        def with(fields = nil, **keyword_fields, &)
          raise ArgumentError, "block required" unless block_given?

          with_fields(fields, keyword_fields) { with_section(it, &) }
        end

        def to_h = section_hash

        def [](key) = nil_if_missing(section_value(key, default: MISSING))

        private

        def coerce_fields(fields, keyword_fields)
          FieldSet.coerce(fields, keyword_fields, invalid: :wrap)
        end

        def add_fields(fields, keyword_fields)
          yield coerce_fields(fields, keyword_fields)
          self
        end

        def with_fields(fields, keyword_fields)
          yield coerce_fields(fields, keyword_fields)
        end

        def nil_if_missing(value)
          value.equal?(MISSING) ? nil : value
        end

        def add_section(fields)
          call_store(:add, fields)
        end

        def with_section(fields, &)
          call_store(:with, fields, &)
        end

        def section_hash
          call_store(:hash)
        end

        def section_value(key, default:)
          call_store(:value, key, default: default)
        end

        def call_store(action, ...)
          @store.public_send(store_method(action), ...)
        end

        def store_method(action)
          STORE_METHODS.fetch(section).fetch(action)
        end

        attr_reader :section
      end

      private_constant :SectionProxy
    end
  end
end
