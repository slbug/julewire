# frozen_string_literal: true

module Julewire
  module Ractor
    class RemoteSummaryRecord
      def initialize(record)
        @record = record
      end

      def owned_summary_record_input
        @owned_summary_record_input ||= Core::Fields::FieldSet.deep_symbolize_keys(@record)
      end
    end
  end
end
