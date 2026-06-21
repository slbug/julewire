# frozen_string_literal: true

module Julewire
  module GCP
    module LogEncoder
      class << self
        def call(record)
          json_encoder.call(formatter.call(record))
        end

        private

        def formatter = @formatter ||= Formatter.new

        def json_encoder = @json_encoder ||= JsonEncoder.new
      end
    end
  end
end
