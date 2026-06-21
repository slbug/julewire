# frozen_string_literal: true

module Julewire
  module Core
    module Execution
      class Lineage
        # Bounded to cap summary growth; also the Answer to the Ultimate Question.
        MAX_ANCESTORS = 42
        RELATIONSHIP_KEYS = %i[depth root parent ancestors ancestors_truncated].freeze
        LAZY_RELATIONSHIP_KEYS = %i[ancestors ancestors_truncated].freeze
        attr_reader :depth, :parent_reference, :root_reference

        class << self
          def clean_execution_hash(execution)
            clean_hash(execution, RELATIONSHIP_KEYS)
          end

          def clean_normalized_lazy_relationship_hash(execution)
            clean_normalized_hash(execution, LAZY_RELATIONSHIP_KEYS)
          end

          def clean_owned_execution_hash(execution)
            clean_hash!(execution, RELATIONSHIP_KEYS)
          end

          def from_execution_hash(execution)
            execution = {} unless execution.is_a?(Hash)
            new(
              reference: execution_reference(execution),
              root_reference: relationship_value(execution, :root),
              parent_reference: relationship_value(execution, :parent),
              depth: relationship_value(execution, :depth),
              ancestors: relationship_value(execution, :ancestors),
              ancestors_truncated: relationship_value(execution, :ancestors_truncated)
            )
          end

          private

          def relationship_value(execution, key)
            Fields::FieldSet.value_for(execution, key)
          end

          def reference_value(execution, key)
            Fields::FieldSet.value_for(execution, key, default: MISSING)
          end

          def clean_hash(execution, keys)
            copy = execution.is_a?(Hash) ? Fields::FieldSet.deep_symbolize_keys(execution) : {}
            clean_hash!(copy, keys)
          end

          def clean_normalized_hash(execution, keys)
            copy = execution.is_a?(Hash) ? execution.dup : {}
            clean_hash!(copy, keys)
          end

          def clean_hash!(copy, keys)
            keys.each do |key|
              Fields::Internal.delete_key!(copy, key)
            end
            copy
          end

          def execution_reference(execution)
            reference = {}
            type = reference_value(execution, :type)
            id = reference_value(execution, :id)
            reference[:type] = type unless type.equal?(MISSING)
            reference[:id] = id unless id.equal?(MISSING)
            reference.empty? ? nil : reference
          end
        end

        def initialize(
          reference: nil,
          parent_lineage: nil,
          parent_reference: nil,
          root_reference: nil,
          depth: nil,
          ancestors: nil,
          ancestors_truncated: false
        )
          @parent_lineage = parent_lineage
          @depth = depth_value(depth, parent_lineage)
          @root_reference = freeze_reference(root_reference || root_reference_for(reference, parent_lineage))
          @parent_reference = freeze_reference(parent_reference)
          @ancestor_references = freeze_ancestors(ancestors)
          @ancestors_truncated = ancestors_truncated ? true : false
          @ancestor_references_for_child = nil
          @truncated = nil
          @truncated_computed = false
        end

        def merge_into_frozen(execution)
          hash = frozen_hash_copy(execution)
          hash[:depth] = depth
          hash[:root] = @root_reference
          hash[:parent] = @parent_reference if @parent_reference
          hash.freeze
        end

        def ancestors
          references = @ancestor_references_for_child
          return references if references

          materialize_ancestor_references_for_child
        end

        def truncated?
          return @truncated if @truncated_computed

          @truncated = @ancestors_truncated || ancestor_count_exceeds_limit?
          @truncated_computed = true
          @truncated
        end

        def freeze
          return self if frozen?

          ancestors
          truncated?
          @parent_lineage = nil
          super
        end

        protected

        def ancestor_references_for_child
          ancestors
        end

        def root_reference_for_child
          @root_reference
        end

        private

        attr_reader :parent_lineage

        def materialize_ancestor_references_for_child
          if @ancestor_references
            @ancestor_references_for_child = @ancestor_references.freeze
          else
            references = build_ancestor_references
            @truncated = references.length > MAX_ANCESTORS
            @truncated_computed = true
            @ancestor_references_for_child = references.last(MAX_ANCESTORS).freeze
          end
        end

        def ancestor_count_exceeds_limit?
          return false if @ancestor_references_for_child

          build_ancestor_references.length > MAX_ANCESTORS
        end

        def depth_value(depth, parent_lineage)
          return depth if depth.is_a?(Integer) && depth.positive?
          return parent_lineage.depth + 1 if parent_lineage

          1
        end

        def root_reference_for(reference, parent_lineage)
          parent_lineage ? parent_lineage.root_reference_for_child : reference
        end

        def build_ancestor_references
          return [] unless parent_lineage && @parent_reference

          parent_lineage.ancestor_references_for_child + [@parent_reference]
        end

        def freeze_ancestors(ancestors)
          return unless ancestors.is_a?(Array)

          Serialization::ValueCopy.call(ancestors, freeze_values: true)
        end

        def freeze_reference(reference)
          return unless reference
          return reference if reference.frozen?

          Serialization::ValueCopy.call(reference, freeze_values: true)
        end

        def frozen_hash_copy(value)
          value.each_with_object({}) do |(key, field_value), copy|
            copy[key] = Serialization::ValueCopy.call(field_value, freeze_values: true)
          end
        end
      end
    end
  end
end
