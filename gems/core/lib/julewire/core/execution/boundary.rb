# frozen_string_literal: true

module Julewire
  module Core
    module Execution
      class Boundary
        EMPTY_HASH = {}.freeze
        EXECUTION_OPTION_DEFAULTS = {
          id: nil,
          fields: EMPTY_HASH,
          attributes: EMPTY_HASH,
          neutral: EMPTY_HASH,
          labels: EMPTY_HASH,
          owned: false,
          inherit_attributes: true,
          emit_summary: true,
          summary_event: nil,
          summary_severity: nil,
          summary_source: nil
        }.freeze
        EXECUTION_OPTION_KEYS = EXECUTION_OPTION_DEFAULTS.keys.freeze
        private_constant :EXECUTION_OPTION_DEFAULTS, :EXECUTION_OPTION_KEYS, :EMPTY_HASH

        def initialize(emit_summary_record:, summary_finalizer_failure:, emit_non_standard_exception_summaries:,
                       before_call: nil)
          @before_call = before_call
          @emit_summary_record = emit_summary_record
          @summary_finalizer_failure = summary_finalizer_failure
          @emit_non_standard_exception_summaries = emit_non_standard_exception_summaries
        end

        def with_execution(type:, **options, &)
          before_call!(:with_execution)
          raise ArgumentError, "block required" unless block_given?

          open_context_execution(:with_execution, type: type, options: options, &)
        end

        def start_execution(type:, **options)
          before_call!(:start_execution)
          open_context_execution(:start_execution, type: type, options: options)
        end

        private

        def before_call!(action)
          @before_call&.call(action)
        end

        def open_context_execution(method_name, type:, options:, &)
          options = normalized_execution_options(options)
          ContextStore.current.public_send(
            method_name,
            type: type,
            id: options.fetch(:id),
            execution: options.fetch(:execution),
            attributes: options.fetch(:attributes),
            neutral: options.fetch(:neutral),
            labels: options.fetch(:labels),
            owned: options.fetch(:owned),
            inherit_attributes: options.fetch(:inherit_attributes),
            on_finish: summary_finalizer(emit_summary_enabled: options.fetch(:emit_summary)),
            on_finish_failure: @summary_finalizer_failure,
            summary_event: options.fetch(:summary_event),
            summary_severity: options.fetch(:summary_severity),
            summary_source: options.fetch(:summary_source),
            &
          )
        end

        def normalized_execution_options(options)
          unknown = options.keys - EXECUTION_OPTION_KEYS
          raise ArgumentError, "unknown execution options: #{unknown.join(", ")}" unless unknown.empty?

          EXECUTION_OPTION_DEFAULTS.merge(options).tap do |normalized|
            normalized[:execution] = execution_fields(normalized.delete(:fields))
            normalized[:attributes] ||= EMPTY_HASH
            normalized[:neutral] ||= EMPTY_HASH
            normalized[:labels] ||= EMPTY_HASH
          end
        end

        def execution_fields(fields)
          return {} if fields.nil?
          raise ArgumentError, "execution fields must be a Hash" unless fields.is_a?(Hash)

          fields
        end

        def summary_finalizer(emit_summary_enabled:)
          return unless emit_summary_enabled

          @summary_finalizer ||= lambda do |scope|
            next if suppress_summary_for_non_standard_exception?(scope)

            @emit_summary_record.call(scope)
          end
        end

        def suppress_summary_for_non_standard_exception?(scope)
          scope.non_standard_exception? && !@emit_non_standard_exception_summaries.call
        end
      end
    end
  end
end
