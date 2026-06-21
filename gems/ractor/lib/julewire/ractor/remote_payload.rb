# frozen_string_literal: true

module Julewire
  module Ractor
    module RemotePayload
      MISSING = Object.new.freeze
      private_constant :MISSING

      class << self
        def extract(payload)
          {
            input: input_value(payload),
            context: hash_value(payload, :context),
            neutral: hash_value(payload, :neutral),
            attributes: hash_value(payload, :attributes),
            carry: hash_value(payload, :carry),
            scope: scope_snapshot(hash_value(payload, :scope))
          }
        end

        def input_value(payload)
          value = Core::Integration::Values::Read.hash_value(payload, :input, default: MISSING)
          value.equal?(MISSING) ? {} : value
        end

        def scope_snapshot(scope_payload)
          Core::Execution::ScopeSnapshot.new(
            execution: hash_value(scope_payload, :execution),
            neutral: hash_value(scope_payload, :neutral),
            attributes: hash_value(scope_payload, :attributes),
            carry: hash_value(scope_payload, :carry),
            labels: hash_value(scope_payload, :labels)
          )
        end

        def hash_value(hash, key)
          value = Core::Integration::Values::Read.hash_value(hash, key)
          value.is_a?(Hash) ? Core::Fields::FieldSet.deep_symbolize_keys(value) : {}
        end
      end
    end
  end
end
