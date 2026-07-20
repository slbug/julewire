# frozen_string_literal: true

require "active_support/parameter_filter"
require "julewire/rails/parameter_filters"

module Julewire
  module Rails
    class ParameterFilterProcessor
      EMPTY_CONTAINER_MARKER = Core.sentinel(:empty_container)
      private_constant :EMPTY_CONTAINER_MARKER

      def initialize(filters = ParameterFilters.configured)
        @filter = build_filter(filters)
        # Rails exposes filter_param for scalar fields; use it to avoid whole-record
        # copies when the filter list has no Proc semantics to preserve.
        @filter_param_fast_path = filter_param_safe?(filters)
        @field_plan = ParameterFilterPlan.build(filters) if @filter_param_fast_path
      end

      def call(draft)
        validate_draft!(draft)
        @filter_param_fast_path ? filter_draft_fields!(draft) : filter_whole_record!(draft)
        draft
      end

      private

      def validate_draft!(draft)
        return if draft.instance_of?(RecordDraft)

        raise TypeError, "expected Julewire::RecordDraft"
      end

      def build_filter(filters)
        ParameterFilters.build(filters)
      end

      def filter_param_safe?(filters)
        return false if filters.respond_to?(:filter) && !filters.is_a?(Array)

        filters = Array(filters)
        filters.none?(Proc)
      end

      def filter_draft_fields!(draft)
        draft.each_key do |key|
          value = draft.fetch(key)
          next if skip_empty_container?(key, value)

          filtered = filter_record_param(key, value)
          draft.transform_field!(key) { filtered }
        end
      end

      def filter_whole_record!(draft)
        draft.transform_record! { @filter.filter(it) }
      end

      def filter_record_param(key, value)
        return @field_plan.filter_value(value) if @field_plan && record_container_key?(key)

        filtered = @filter.filter_param(key, value)
        return filtered unless record_container_key?(key) && !filtered.instance_of?(Hash)
        return value unless value.is_a?(Hash)

        @filter.filter(value)
      end

      def skip_empty_container?(key, value)
        return false unless empty_container?(value)
        return true if record_container_key?(key)

        @filter.filter_param(key, EMPTY_CONTAINER_MARKER).equal?(EMPTY_CONTAINER_MARKER)
      end

      def empty_container?(value)
        (value.is_a?(Hash) || value.is_a?(Array)) && value.empty?
      end

      def record_container_key?(key)
        Core::Processing::RecordFieldTransform.container_key?(key)
      end
    end
  end
end
