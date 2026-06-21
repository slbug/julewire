# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      module Contracts
        module RecordDraft
          def assert_julewire_record_draft_transform_contract(draft: build_julewire_transform_contract_draft)
            draft.transform_field!(:message) { |message| "#{message} transformed" }
            draft.transform_section!(:payload) { it.merge(section_transformed: true) }
            draft.transform_record! do |data|
              data.merge(labels: data.fetch(:labels).merge(record_transformed: "yes"))
            end

            record = draft.to_record
            assert_equal "test message transformed", record.fetch(:message)
            assert record.dig(:payload, :section_transformed)
            assert_equal "yes", record.dig(:labels, :record_transformed)
            assert_equal [{ type: "request", id: "root-1" }], record.lineage.ancestors
            draft
          end

          def build_julewire_transform_contract_draft
            build_julewire_contract_draft(
              execution: {
                type: "job",
                id: "job-1",
                ancestors: [{ type: "request", id: "root-1" }]
              },
              labels: { service: "contract" }
            )
          end
        end
      end
    end
  end
end
