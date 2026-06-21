# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      class StaticLabels
        def initialize
          @fields = {}
        end

        def add(fields = nil, **keyword_fields)
          FieldSet.merge!(@fields, FieldSet.coerce(fields, keyword_fields, invalid: :raise))
          self
        end

        def clear
          @fields.clear
          self
        end

        def remove(key)
          Fields::Internal.delete_key!(@fields, key)
          self
        end

        def to_h
          FieldSet.deep_dup(@fields)
        end

        def copy
          self.class.new.tap do |copy|
            copy.add(to_h)
          end
        end

        def freeze
          @fields.freeze
          super
        end
      end
    end
  end
end
