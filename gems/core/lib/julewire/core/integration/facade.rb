# frozen_string_literal: true

module Julewire
  module Core
    module Integration
      # @api integration_spi
      module Facade
        class << self
          def emit(record = Core::UNSET, enforce_level: true, **fields)
            record = Core.emit_input(record, fields)
            runtime = RuntimeLocator.current
            if runtime.respond_to?(:emit_integration)
              runtime.emit_integration(record, enforce_level: enforce_level)
            elsif enforce_level
              runtime.emit(record)
            else
              runtime.emit_without_level(record)
            end
            nil
          end

          def with_execution(type:, **, &)
            raise ArgumentError, "block required" unless block_given?

            integration_write_section!(:execution)
            RuntimeLocator.current.with_execution(type: type, owned: true, **, &)
          end

          def with_attributes(fields, &)
            with_fields(:attributes, fields, &)
          end

          def with_neutral(fields, &)
            with_fields(:neutral, fields, &)
          end

          def with_carry(fields, &)
            with_fields(:carry, fields, &)
          end

          def with_context(fields, &)
            with_fields(:context, fields, &)
          end

          def add_context(fields)
            add_fields(:context, fields)
          end

          def add_attributes(fields)
            add_fields(:attributes, fields)
          end

          def add_neutral(fields)
            add_fields(:neutral, fields)
          end

          def add_carry(fields)
            add_fields(:carry, fields)
          end

          def add_summary_attributes(fields)
            add_summary_fields(fields, :add_summary_attributes)
          end

          def add_summary_neutral(fields)
            add_summary_fields(fields, :add_summary_neutral)
          end

          def summary_active?
            current_scope?
          end

          def increment_summary_attribute(*path, by: 1)
            scope = ContextStore.current.current_scope
            return unless scope

            scope.increment_summary_attribute(path, by: by)
            nil
          end

          private

          def current_scope?
            ContextStore.current.current_scope?
          end

          def with_fields(section, fields, &)
            raise ArgumentError, "block required" unless block_given?

            integration_write_section!(section)
            case section
            when :attributes then ContextStore.current.with_attributes(fields, owned: true, &)
            when :carry then ContextStore.current.with_carry(fields, owned: true, &)
            when :context then ContextStore.current.with_context(fields, owned: true, &)
            when :neutral then ContextStore.current.with_neutral(fields, owned: true, &)
            end
          end

          def add_fields(section, fields)
            integration_write_section!(section)
            case section
            when :attributes then ContextStore.current.add_attributes(fields, owned: true)
            when :carry then ContextStore.current.add_carry(fields, owned: true)
            when :context then ContextStore.current.add_context(fields, owned: true)
            when :neutral then ContextStore.current.add_neutral(fields, owned: true)
            end
            nil
          end

          def integration_write_section!(section)
            # Keep the failure path close to the table it protects; new field
            # bags should not become integration-writable by accident.
            return if Fields::Bags.integration_write_sections.include?(section)

            raise ArgumentError, "integration cannot write #{section}"
          end

          def add_summary_fields(fields, writer)
            integration_write_section!(:summary)
            scope = ContextStore.current.current_scope
            return unless scope && fields.is_a?(Hash)

            fields = Serialization::DeepCompactEmpty.compact_owned!(fields)
            scope.public_send(writer, fields, owned: true) unless fields.empty?
            nil
          end
        end
      end
    end
  end
end
