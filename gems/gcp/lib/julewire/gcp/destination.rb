# frozen_string_literal: true

module Julewire
  module GCP
    class Destination < Julewire::Core::Destinations::Destination
      def initialize(output:, name: :gcp, formatter: nil, encoder: Julewire::JsonEncoder.new,
                     max_record_bytes: DEFAULT_MAX_RECORD_BYTES, close_output: false, on_drop: nil,
                     on_failure: nil)
        super(
          name: name,
          close_output: close_output,
          encoder: encoder,
          formatter: formatter || Formatter.new,
          max_record_bytes: max_record_bytes,
          on_drop: on_drop,
          on_failure: on_failure,
          output: output
        )
      end
    end
  end
end
