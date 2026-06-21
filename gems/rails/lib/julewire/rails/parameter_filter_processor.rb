# frozen_string_literal: true

require "active_support/parameter_filter"

module Julewire
  module Rails
    class ParameterFilterProcessor
      EMPTY_CONTAINER_MARKER = Core.sentinel(:empty_container)
      private_constant :EMPTY_CONTAINER_MARKER

      def initialize(filters = rails_filter_parameters)
        @filter = build_filter(filters)
        # Rails exposes filter_param for scalar fields; use it to avoid whole-record
        # copies when the filter list has no Proc semantics to preserve. Regex-only
        # filters fall back to whole-record filtering unless they can scalarize a
        # required record container.
        @filter_param_fast_path = filter_param_safe?(filters) && @filter.respond_to?(:filter_param)
        @field_plan = ParameterFilterPlan.build(filters) if @filter_param_fast_path
      end

      def call(draft)
        validate_draft!(draft)
        return if @filter.nil?

        @filter_param_fast_path ? filter_draft_fields!(draft) : filter_whole_record!(draft)
      end

      private

      def validate_draft!(draft)
        return draft if draft.is_a?(Julewire::RecordDraft)

        raise TypeError, "expected Julewire::RecordDraft"
      end

      def build_filter(filters)
        return filters if filters.respond_to?(:filter) && !filters.is_a?(Array)

        filters = Array(filters)
        return if filters.empty?

        ::ActiveSupport::ParameterFilter.new(::ActiveSupport::ParameterFilter.precompile_filters(filters))
      end

      def filter_param_safe?(filters)
        return false if filters.respond_to?(:filter) && !filters.is_a?(Array)

        filters = Array(filters)
        return false if filters.any?(Proc)

        filters.none?(Regexp) || filters.any? { regexp_matches_record_container?(it) }
      end

      def regexp_matches_record_container?(filter)
        filter.is_a?(Regexp) && Core::Processing::RecordFieldTransform.container_keys.any? { filter.match?(it.name) }
      end

      def filter_draft_fields!(draft)
        each_filter_field_key(draft) do |key|
          next unless draft.key?(key)

          value = draft[key]
          next if skip_empty_container?(key, value)

          filtered = filter_record_param(key, value)
          draft.transform_field!(key) { filtered } unless filtered.equal?(value)
        end
        draft
      end

      def each_filter_field_key(draft, &)
        return @field_plan.filtered_field_keys.each(&) if @field_plan&.filtered_field_keys

        draft.each_key(&)
      end

      def filter_whole_record!(draft)
        draft.transform_record! { @filter.filter(it) }
      end

      def filter_record_param(key, value)
        if @field_plan&.direct_container_filter? && record_container_key?(key) && value.is_a?(Hash)
          return @field_plan.filter_value(value)
        end

        filtered = @filter.filter_param(key, value)
        return filtered unless record_container_key?(key) && !filtered.is_a?(Hash)
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

      def rails_filter_parameters
        app = ::Rails.application if defined?(::Rails) && ::Rails.respond_to?(:application)
        config = app.config if app.respond_to?(:config)
        config.filter_parameters if config.respond_to?(:filter_parameters)
      rescue StandardError
        []
      end
    end
  end
end
