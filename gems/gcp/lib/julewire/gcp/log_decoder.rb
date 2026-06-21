# frozen_string_literal: true

module Julewire
  module GCP
    module LogDecoder
      RecordDecoder = Core::CLI::LogFormats::RecordDecoder
      private_constant :RecordDecoder

      JULEWIRE_SECTION_KEYS = {
        execution: "execution",
        context: "context",
        metrics: "metrics"
      }.freeze
      PAYLOAD_SECTION_KEYS = {
        attributes: "attributes",
        labels: "logging.googleapis.com/labels",
        payload: "payload"
      }.freeze
      private_constant :JULEWIRE_SECTION_KEYS, :PAYLOAD_SECTION_KEYS

      class << self
        def match?(payload)
          payload[JULEWIRE_PAYLOAD_FIELD].is_a?(Hash)
        end

        def call(payload)
          julewire = payload.fetch(JULEWIRE_PAYLOAD_FIELD)
          record_base(payload, julewire).merge(
            record_sections(payload, julewire),
            error: RecordDecoder.error(julewire["error"])
          )
        end

        private

        def record_base(payload, julewire)
          {
            timestamp: payload["time"] || payload["timestamp"],
            severity: Julewire::Core::Records::Severity.normalize(payload["severity"] || :info),
            kind: RecordDecoder.kind(julewire["kind"] || :point),
            event: julewire["event"],
            message: payload["message"],
            logger: julewire["logger"],
            source: julewire["source"]
          }
        end

        def record_sections(payload, julewire)
          RecordDecoder.sections(payload) do |section, _source|
            gcp_section_value(section, payload, julewire)
          end
        end

        def gcp_section_value(section, payload, julewire)
          if (key = JULEWIRE_SECTION_KEYS[section])
            julewire[key]
          elsif (key = PAYLOAD_SECTION_KEYS[section])
            payload[key]
          end
        end
      end
    end
  end
end
