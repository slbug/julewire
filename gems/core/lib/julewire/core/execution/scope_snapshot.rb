# frozen_string_literal: true

module Julewire
  module Core
    module Execution
      class ScopeSnapshot
        def initialize(execution: {}, carry: {}, attributes: {}, labels: {}, neutral: {}, lineage: nil, owned: false)
          @owned = owned
          @execution = normalized_hash(execution)
          @carry = normalized_hash(carry)
          @attributes = normalized_hash(attributes)
          @neutral = normalized_hash(neutral)
          @labels = normalized_hash(labels)
          @lineage = lineage || Lineage.from_execution_hash(@execution)
        end

        def execution_hash
          Fields::FieldSet.deep_dup_owned(frozen_execution_hash)
        end

        def frozen_execution_hash
          @frozen_execution_hash ||= Fields::Internal.frozen_owned_copy(@execution)
        end

        attr_reader :lineage

        def id = @execution[:id]

        def type = @execution[:type]

        def started_at; end

        def finished_at; end

        def parent; end

        def context_hash = {}

        def carry_hash = Fields::FieldSet.deep_dup_owned(@carry)

        def attributes_hash = Fields::FieldSet.deep_dup_owned(@attributes)

        def neutral_hash = Fields::FieldSet.deep_dup_owned(@neutral)

        def labels_hash = Fields::FieldSet.deep_dup_owned(@labels)

        def summary_hash = {}

        def metrics_hash = {}

        def frozen_labels_hash = (@frozen_labels_hash ||= Fields::Internal.frozen_owned_copy(@labels))

        def execution_reference_for_child
          reference = {}
          reference[:type] = @execution.fetch(:type) if @execution.key?(:type)
          reference[:id] = @execution.fetch(:id) if @execution.key?(:id)
          Fields::Internal.frozen_copy(reference) unless reference.empty?
        end

        private

        def normalized_hash(value)
          return Fields::FieldSet.deep_symbolize_keys(value) unless @owned

          Serialization::DeepFreeze.validate_symbol_hash(value)
          Fields::FieldSet.deep_dup_owned(value)
        end
      end
    end
  end
end
