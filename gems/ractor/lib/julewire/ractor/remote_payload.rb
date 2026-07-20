# frozen_string_literal: true

module Julewire
  module Ractor
    module RemotePayload
      class << self
        def extract(payload)
          validate_hash!(payload)
          {
            input: hash_value(payload, :input),
            context: hash_value(payload, :context),
            neutral: hash_value(payload, :neutral),
            attributes: hash_value(payload, :attributes),
            carry: hash_value(payload, :carry),
            scope: scope_snapshot(hash_value(payload, :scope))
          }
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
          validate_hash!(hash.fetch(key))
        end

        private

        def validate_hash!(value)
          Core::Integration::Protocol.validate_symbol_hash(value)
        end
      end
    end
  end
end
