# frozen_string_literal: true

module Julewire
  module Core
    class CLI
      module LogFormats
        module CoreJsonEncoder
          class << self
            def call(record)
              json_encoder.call(Records::Formatter.new.call(record))
            end

            private

            def json_encoder = @json_encoder ||= Serialization::JsonEncoder.new
          end
        end
      end
    end
  end
end
