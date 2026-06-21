# frozen_string_literal: true

module Julewire
  module Core
    class CLI
      module LogFormats
        module CoreJsonDecoder
          class << self
            CORE_KINDS = {
              "point" => true,
              "summary" => true
            }.freeze

            def match?(payload)
              payload.key?("timestamp") &&
                payload.key?("severity") &&
                CORE_KINDS.key?(payload["kind"].to_s)
            end

            def call(payload)
              record_base(payload).merge(record_sections(payload), error: RecordDecoder.error(payload["error"]))
            end

            private

            def record_base(source)
              {
                timestamp: source["timestamp"],
                severity: Records::Severity.normalize(source["severity"] || :info),
                kind: RecordDecoder.kind(source["kind"] || :point),
                event: source["event"],
                message: source["message"],
                logger: source["logger"],
                source: source["source"]
              }
            end

            def record_sections(source)
              RecordDecoder.sections(source)
            end
          end
        end
      end
    end
  end
end
