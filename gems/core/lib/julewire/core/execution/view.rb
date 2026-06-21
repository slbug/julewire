# frozen_string_literal: true

module Julewire
  module Core
    module Execution
      # @api public
      # Read-only view returned by Julewire.current_execution.
      class View
        attr_reader :finished_at, :id, :lineage, :started_at, :type

        def initialize(scope)
          @scope = scope
          @id = scope.id
          @type = scope.type
          @started_at = scope.started_at
          @finished_at = scope.finished_at
          @parent_scope = scope.parent
          @lineage = scope.lineage
          @parent = nil
          @execution_hash = nil
          @context_hash = nil
          @carry_hash = nil
          @neutral_hash = nil
          @attributes_hash = nil
          @labels_hash = nil
          @summary_hash = nil
          @metrics_hash = nil
        end

        def parent
          return unless @parent_scope

          @parent ||= self.class.new(@parent_scope)
        end

        def execution_hash = Fields::FieldSet.deep_dup(@execution_hash ||= @scope.frozen_execution_hash)

        def context_hash = Fields::FieldSet.deep_dup(@context_hash ||= @scope.context_hash)

        def carry_hash = Fields::FieldSet.deep_dup(@carry_hash ||= @scope.carry_hash)

        def neutral_hash = Fields::FieldSet.deep_dup(@neutral_hash ||= @scope.neutral_hash)

        def attributes_hash = Fields::FieldSet.deep_dup(@attributes_hash ||= @scope.attributes_hash)

        def labels_hash = Fields::FieldSet.deep_dup(@labels_hash ||= @scope.frozen_labels_hash)

        def summary_hash = Fields::FieldSet.deep_dup(@summary_hash ||= @scope.summary_hash)

        def metrics_hash = Fields::FieldSet.deep_dup(@metrics_hash ||= @scope.metrics_hash)

        def finished? = !finished_at.nil?
      end
    end
  end
end
