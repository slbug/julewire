# frozen_string_literal: true

module Julewire
  module Rails
    module ParameterFilters
      class << self
        def configured
          Array(::Rails.application.config.filter_parameters)
        rescue StandardError
          []
        end

        def build(filters)
          return filters if filters.respond_to?(:filter) && !filters.is_a?(Array)

          ActiveSupport::ParameterFilter.new(Array(filters))
        end
      end
    end
  end
end
