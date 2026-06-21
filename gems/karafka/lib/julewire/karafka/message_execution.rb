# frozen_string_literal: true

module Julewire
  module Karafka
    module MessageExecution
      DEFAULT_TYPE = :karafka_message
      DEFAULT_SUMMARY_EVENT = "message.completed"

      class << self
        def call(message, configuration: Configuration.new, **options, &)
          raise ArgumentError, "block required" unless block_given?

          fields = PayloadReader.message_payload(message)
          execution_fields = execution_fields(options)
          type = execution_fields.delete(:type) || DEFAULT_TYPE
          id = execution_fields.delete(:id) || execution_id(fields)
          emit_summary = execution_fields.delete(:emit_summary) { true }
          summary_event = execution_fields.delete(:summary_event) || DEFAULT_SUMMARY_EVENT
          summary_severity = execution_fields.delete(:summary_severity)
          summary_source = execution_fields.delete(:summary_source) || configuration.source
          MessageContext.call(message, configuration: configuration, fields: fields) do
            Julewire::Core::Integration::Facade.with_execution(
              type: type,
              id: id,
              emit_summary: emit_summary,
              fields: execution_fields,
              summary_event: summary_event,
              summary_severity: summary_severity,
              summary_source: summary_source,
              &
            )
          end
        end

        private

        def execution_fields(options)
          values = Core::Integration::Values::Shape
          fields = values.hash_or_empty(options)
          fields.empty? ? {} : fields
        end

        def execution_id(fields)
          topic = fields[:topic]
          partition = fields[:partition]
          offset = fields[:offset]
          return if topic.nil? || partition.nil? || offset.nil?

          "#{topic}:#{partition}:#{offset}"
        end
      end
    end
  end
end
