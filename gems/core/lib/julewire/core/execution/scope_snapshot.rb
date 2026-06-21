# frozen_string_literal: true

module Julewire
  module Core
    module Execution
      class ScopeSnapshot
        EMPTY_HASH = {}.freeze
        private_constant :EMPTY_HASH

        def initialize(execution: {}, carry: {}, attributes: {}, labels: {}, neutral: {}, lineage: nil)
          @execution = normalized_hash(execution)
          @carry = normalized_hash(carry)
          @attributes = normalized_hash(attributes)
          @neutral = normalized_hash(neutral)
          @labels = normalized_hash(labels)
          @lineage = lineage || Lineage.from_execution_hash(@execution)
        end

        def execution_hash
          Fields::FieldSet.deep_dup(frozen_execution_hash)
        end

        def frozen_execution_hash
          @frozen_execution_hash ||= Fields::Internal.frozen_copy(@execution)
        end

        attr_reader :lineage

        def id = @execution[:id]

        def type = @execution[:type]

        def started_at = nil

        def finished_at = nil

        def parent = nil

        def context_hash = {}

        def carry_hash
          return {} if @carry.empty?

          Fields::FieldSet.deep_dup(@carry)
        end

        def attributes_hash
          return {} if @attributes.empty?

          Fields::FieldSet.deep_dup(@attributes)
        end

        def neutral_hash
          return {} if @neutral.empty?

          Fields::FieldSet.deep_dup(@neutral)
        end

        def labels_hash
          return {} if @labels.empty?

          Fields::FieldSet.deep_dup(@labels)
        end

        def summary_hash = {}

        def metrics_hash = {}

        def frozen_labels_hash
          return EMPTY_HASH if @labels.empty?

          @frozen_labels_hash ||= Fields::Internal.frozen_copy(@labels)
        end

        def execution_reference_for_child
          reference = {}
          reference[:type] = @execution[:type] if @execution.key?(:type)
          reference[:id] = @execution[:id] if @execution.key?(:id)
          reference.empty? ? nil : Fields::Internal.frozen_copy(reference)
        end

        private

        def normalized_hash(value)
          return EMPTY_HASH if value.is_a?(Hash) && value.empty?

          Fields::FieldSet.deep_symbolize_keys(value)
        end
      end
    end
  end
end
