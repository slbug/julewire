# frozen_string_literal: true

module Julewire
  module Core
    # @api public
    module Propagation
      FIELD_SECTIONS = (Fields::Bags.propagation_sections - [:execution]).freeze
      private_constant :FIELD_SECTIONS

      class << self
        def capture
          capture_with { Serialization::Serializer.call(it) }
        end

        def capture_local
          capture_with { Fields::FieldSet.deep_dup_owned(it) }
        end

        def restore(envelope, link_executions: false, owned: false, &)
          raise ArgumentError, "block required" unless block_given?

          Integration::Protocol.validate_symbol_hash(envelope) if owned
          sections = FIELD_SECTIONS.to_h do |section|
            [section, restore_hash_value(envelope, section, owned: owned)]
          end
          execution = restore_hash_value(envelope, :execution, owned: owned)
          ContextStore.current.with_propagation(
            **sections,
            execution: execution,
            link_executions: link_executions,
            owned: owned,
            &
          )
        end

        private

        def capture_with
          store = ContextStore.current
          scope = store.current_scope_or_snapshot
          envelope = FIELD_SECTIONS.to_h { |section| [section, yield(store.public_send(:"#{section}_hash"))] }
          execution = scope ? scope.execution_hash : {}
          envelope[:execution] = yield(execution) unless execution.empty?
          envelope
        end

        def hash_value(hash, key)
          value = Fields::FieldSet.value_for(hash, key)
          value.is_a?(Hash) ? value : {}
        end

        def restore_hash_value(envelope, key, owned:)
          return hash_value(envelope, key) unless owned
          return {} unless envelope.key?(key)

          value = envelope.fetch(key)
          return value if value.is_a?(Hash)

          raise TypeError, "propagation #{key} must be a Hash"
        end
      end
    end
  end
end
