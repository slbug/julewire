# frozen_string_literal: true

module Julewire
  module Core
    module Fields
      # @api extension
      module Bags
        Definition = Data.define(
          :name,
          :record_hash,
          :transform_container,
          :app_write,
          :integration_write,
          :propagate,
          :emit_by_default,
          :delete_paths,
          :stack
        )
        RECORD_SCALAR_KEYS = %i[
          timestamp
          severity
          kind
          event
          message
          logger
          source
        ].freeze

        class << self
          private

          def define(name, **capabilities)
            Definition.new(
              name: name,
              record_hash: true,
              transform_container: true,
              app_write: false,
              integration_write: false,
              propagate: false,
              emit_by_default: true,
              delete_paths: false,
              stack: false,
              **capabilities
            )
          end
        end

        DEFINITIONS = {
          execution: define(:execution, integration_write: true, propagate: true),
          context: define(
            :context,
            app_write: true,
            integration_write: true,
            propagate: true,
            stack: true
          ),
          carry: define(
            :carry,
            app_write: true,
            integration_write: true,
            propagate: true,
            emit_by_default: false,
            delete_paths: true,
            stack: true
          ),
          neutral: define(:neutral, integration_write: true, emit_by_default: false, stack: true),
          attributes: define(
            :attributes,
            app_write: true,
            integration_write: true,
            stack: true
          ),
          labels: define(:labels),
          payload: define(:payload),
          metrics: define(:metrics),
          error: define(:error, record_hash: false),
          summary: define(
            :summary,
            record_hash: false,
            transform_container: false,
            integration_write: true,
            emit_by_default: false
          )
        }.freeze
        private_constant :Definition, :DEFINITIONS, :RECORD_SCALAR_KEYS

        class << self
          def definition(name) = DEFINITIONS.fetch(name)

          def record_scalar_keys = RECORD_SCALAR_KEYS

          def record_hash_sections = select_names(:record_hash)

          def required_record_keys = (record_scalar_keys + record_hash_sections + %i[error]).freeze

          def transform_container_sections = select_names(:transform_container)

          def hidden_output_sections
            DEFINITIONS.filter_map do |name, definition|
              name if definition.record_hash && !definition.emit_by_default
            end.freeze
          end

          def app_write_sections = select_names(:app_write)

          def integration_write_sections = select_names(:integration_write)

          def propagation_sections = select_names(:propagate)

          def stack_sections = select_names(:stack)

          def delete_paths?(name) = definition(name).delete_paths

          private

          def select_names(attribute)
            DEFINITIONS.filter_map { |name, definition| name if definition.public_send(attribute) }.freeze
          end
        end
      end
    end
  end
end
