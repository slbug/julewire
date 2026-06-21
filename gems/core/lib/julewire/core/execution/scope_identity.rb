# frozen_string_literal: true

require "securerandom"

module Julewire
  module Core
    module Execution
      class ScopeIdentity
        attr_reader :id, :lineage, :parent, :reference, :started_at, :started_monotonic, :type

        def initialize(type:, id: nil, started_at: nil, parent: nil, parent_reference: nil)
          @id = normalize_id(id || SecureRandom.uuid)
          @type = normalize_type(type)
          @started_at = frozen_time(started_at || Time.now.utc)
          @started_monotonic = monotonic_time
          @parent = parent
          @reference = { type: @type, id: @id }.freeze
          @lineage = Lineage.new(
            reference: @reference,
            parent_lineage: parent&.lineage,
            parent_reference: parent_reference
          )
        end

        def depth = @lineage.depth

        def execution_fields(execution, owned:)
          fields = owned ? Lineage.clean_owned_execution_hash(execution) : Lineage.clean_execution_hash(execution)
          fields[:type] = @type
          fields[:id] = @id
          fields
        end

        def frozen_execution_hash(execution)
          @lineage.merge_into_frozen(execution)
        end

        def frozen_time(value)
          Serialization::ValueCopy.call(value, freeze_values: true)
        end

        private

        def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def normalize_type(type)
          normalized = type.to_s
          raise ArgumentError, "execution type is required" if normalized.empty?

          freeze_identity_value(normalized)
        end

        def normalize_id(id)
          freeze_identity_value(id)
        end

        def freeze_identity_value(value)
          case value
          when String
            copy = value.frozen? ? value : value.dup
            copy.freeze
          when Symbol, Numeric, true, false, nil
            value
          else
            Serialization::ValueCopy.call(value, freeze_values: true)
          end
        end
      end
    end
  end
end
