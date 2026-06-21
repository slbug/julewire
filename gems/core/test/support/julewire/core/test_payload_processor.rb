# frozen_string_literal: true

module Julewire
  class TestPayloadProcessor
    def initialize(key:, value:)
      @key = key
      @value = value
    end

    def call(record)
      record[:payload][@key] = @value
      nil
    end
  end
end
