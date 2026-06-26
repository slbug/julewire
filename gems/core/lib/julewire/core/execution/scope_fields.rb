# frozen_string_literal: true

module Julewire
  module Core
    module Execution
      class ScopeFields
        EMPTY_HASH = {}.freeze
        private_constant :EMPTY_HASH

        attr_reader :stacks

        def initialize(context:, attributes:, labels:, carry:, neutral:)
          @stacks = Fields::StackSet.new(
            context: context,
            carry: carry,
            attributes: attributes,
            neutral: neutral
          )
          @labels = normalized_static_hash(labels)
        end

        def context_hash = @stacks.snapshot(:context)

        def carry_hash = @stacks.snapshot(:carry)

        def attributes_hash = @stacks.snapshot(:attributes)

        def neutral_hash = @stacks.snapshot(:neutral)

        def field_hash(section)
          @stacks.snapshot(section)
        end

        def field_stack(section)
          @stacks.stack(section)
        end

        def labels_hash
          return {} if @labels.empty?

          Fields::FieldSet.deep_dup(@labels)
        end

        def frozen_labels_hash
          return EMPTY_HASH if @labels.empty?

          @frozen_labels_hash ||= Fields::Internal.frozen_copy(@labels)
        end

        def add(section, fields, owned: false)
          @stacks.add(section, fields, owned: owned)
        end

        def delete(section, path)
          @stacks.delete(section, path)
        end

        def with(section, fields = nil, owned: false, **keyword_fields, &)
          @stacks.with(section, fields, owned: owned, **keyword_fields, &)
        end

        def without(section, path, &)
          @stacks.without(section, path, &)
        end

        private

        def normalized_static_hash(value)
          return EMPTY_HASH if value.is_a?(Hash) && value.empty?

          Fields::FieldSet.deep_symbolize_keys(value)
        end
      end
    end
  end
end
