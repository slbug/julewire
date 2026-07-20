# frozen_string_literal: true

module Julewire
  module Core
    # @api internal
    # Fiber-local context stack used by the runtime facade. Use Julewire.context
    # and Julewire.with_execution instead of reaching into this class directly.
    class ContextStore # rubocop:disable Metrics/ClassLength
      PropagationOverlay = Data.define(:execution, :link_executions)
      private_constant :PropagationOverlay

      class << self
        def current
          LocalStorage.context_store
        end

        # Reset only clears the caller's current thread/fiber context.
        def reset_current! = LocalStorage.reset_context_store!
      end

      def initialize
        reset!
      end

      def reset!
        @scopes = []
        @ambient_fields = Fields::StackSet.new
        @execution_overlays = []
        @propagation_execution_hash = nil
      end

      def current_scope = @scopes.last

      def current_scope? = !!current_scope

      def current_scope_or_snapshot
        current_scope || propagation_scope_snapshot
      end

      def context_proxy
        @context_proxy ||= Fields::ContextProxy.new(self)
      end

      def carry_proxy
        @carry_proxy ||= Fields::CarryProxy.new(self)
      end

      def attributes_proxy
        @attributes_proxy ||= Fields::AttributesProxy.new(self)
      end

      def summary_proxy
        @summary_proxy ||= Fields::SummaryProxy.new(self)
      end

      def context_hash
        current_field_hash(:context)
      end

      def carry_hash
        current_field_hash(:carry)
      end

      def attributes_hash
        current_field_hash(:attributes)
      end

      def neutral_hash
        current_field_hash(:neutral)
      end

      # SectionProxy dispatches these dynamically from the public field readers.
      def context_value(key, default:)
        current_field_stack(:context).value_for(key, default: default)
      end

      def carry_value(key, default:)
        current_field_stack(:carry).value_for(key, default: default)
      end

      def attributes_value(key, default:)
        current_field_stack(:attributes).value_for(key, default: default)
      end

      def add_context(fields = nil, owned: false, **keyword_fields)
        add_field(:context, field_input(fields, keyword_fields), owned: owned)
      end

      def add_carry(fields = nil, owned: false, **keyword_fields)
        add_field(:carry, field_input(fields, keyword_fields), owned: owned)
      end

      def add_attributes(fields = nil, owned: false, **keyword_fields)
        add_field(:attributes, field_input(fields, keyword_fields), owned: owned)
      end

      def add_neutral(fields = nil, owned: false, **keyword_fields)
        add_field(:neutral, field_input(fields, keyword_fields), owned: owned)
      end

      def delete_carry(path)
        path = Fields::Internal.normalize_path(path)
        if current_scope
          current_scope.delete_carry(path)
        else
          @ambient_fields.delete(:carry, path)
        end
      end

      def with_context(fields = nil, owned: false, **keyword_fields, &)
        with_scope_or_ambient_overlay(:context, field_input(fields, keyword_fields), owned: owned, &)
      end

      def with_carry(fields = nil, owned: false, **keyword_fields, &)
        with_scope_or_ambient_overlay(:carry, field_input(fields, keyword_fields), owned: owned, &)
      end

      def with_attributes(fields = nil, owned: false, **keyword_fields, &)
        with_scope_or_ambient_overlay(:attributes, field_input(fields, keyword_fields), owned: owned, &)
      end

      def with_neutral(fields = nil, owned: false, **keyword_fields, &)
        with_scope_or_ambient_overlay(:neutral, field_input(fields, keyword_fields), owned: owned, &)
      end

      def without_carry(path, &)
        scope = current_scope
        normalized_path = Fields::Internal.normalize_path(path)
        raise ArgumentError, "carry path is required" if normalized_path.empty?

        if scope
          scope.without_carry(normalized_path, &)
        else
          @ambient_fields.without(:carry, normalized_path, &)
        end
      end

      def with_propagation(context:, carry:, execution:, link_executions:, owned:, &)
        execution = if owned
                      Serialization::DeepFreeze.validate_symbol_hash(execution)
                    else
                      Fields::FieldSet.deep_symbolize_keys(execution)
                    end
        @execution_overlays.push(PropagationOverlay.new(execution: execution, link_executions: link_executions))
        invalidate_propagation_cache!

        begin
          with_carry(carry, owned: owned) do
            with_context(context, owned: owned, &)
          end
        ensure
          @execution_overlays.pop
          invalidate_propagation_cache!
        end
      end

      def with_execution(**options)
        scope = build_scope(options)
        active_exception = nil

        @scopes.push(scope)
        begin
          yield Execution::View.new(scope)
        rescue Exception => e # rubocop:disable Lint/RescueException
          active_exception = e
          raise
        ensure
          scope.record_error(active_exception) if active_exception
          @scopes.pop
          finish_scope(
            scope,
            options[:on_finish],
            options[:on_finish_failure],
            active_exception: active_exception
          )
        end
      end

      def start_execution(**options)
        scope = build_scope(options)
        Execution::Handle.new(
          scope: scope,
          on_finish: options[:on_finish],
          on_finish_failure: options[:on_finish_failure]
        )
      end

      def with_scope(scope)
        @scopes.push(scope)
        yield Execution::View.new(scope)
      ensure
        @scopes.pop
      end

      private

      def build_scope(options)
        parent_scope = current_scope
        fields = inherited_fields(options, parent_scope)
        Execution::Scope.new(
          type: options.fetch(:type),
          id: options[:id],
          execution: merged_execution_hash(options.fetch(:execution, {}), owned: options.fetch(:owned, false)),
          execution_owned: true,
          context: fields.stack(:context),
          attributes: fields.stack(:attributes),
          neutral: fields.stack(:neutral),
          labels: options[:labels],
          carry: fields.stack(:carry),
          parent: parent_scope || linked_propagation_scope_snapshot,
          started_at: options[:started_at],
          summary_event: options[:summary_event],
          summary_severity: options[:summary_severity],
          summary_source: options[:summary_source]
        )
      end

      def inherited_fields(options, parent_scope)
        inherit = options.fetch(:inherit_attributes, true)
        fields = inherited_stack_set(parent_scope, inherit_attributes: inherit)
        add_scope_stack(fields, options, section: :attributes, key: :attributes)
        add_scope_stack(fields, options, section: :neutral, key: :neutral)
        fields
      end

      def add_scope_stack(stack_set, options, section:, key:)
        value = options[key]
        if options.fetch(:owned, false)
          stack_set.add(section, value, owned: true)
        else
          stack_set.add(section, value)
        end
      end

      def add_field(section, fields, owned:)
        scope = current_scope
        if scope
          scope.add_field(section, fields, owned: owned)
        else
          @ambient_fields.add(section, fields, owned: owned)
        end
      end

      def field_input(fields, keyword_fields)
        return fields if keyword_fields.empty?

        Fields::FieldSet.coerce(fields, keyword_fields, invalid: :wrap)
      end

      def with_scope_or_ambient_overlay(section, fields, owned:, &)
        scope = current_scope
        return scope.with_field(section, fields, owned: owned, &) if scope

        @ambient_fields.with(section, fields, owned: owned, &)
      end

      def current_field_stack(section)
        scope = current_scope
        return @ambient_fields.stack(section) unless scope

        scope.field_stack(section)
      end

      def current_field_hash(section)
        scope = current_scope
        scope ? scope.field_hash(section) : @ambient_fields.snapshot(section)
      end

      def inherited_stack_set(parent_scope, inherit_attributes:)
        source = parent_scope ? parent_scope.field_stacks : @ambient_fields
        Fields::StackSet.inherit_from(source, inherit_attributes: inherit_attributes)
      end

      def execution_hash
        Fields::FieldSet.deep_dup_owned(propagation_execution_hash)
      end

      def propagation_execution_hash
        @propagation_execution_hash ||= Fields::Internal.frozen_owned_copy(
          @execution_overlays.reduce({}) do |memo, overlay|
            Fields::Internal.merge_owned!(memo, overlay.execution)
          end
        )
      end

      def propagation_scope_snapshot
        execution = propagation_execution_hash
        return if execution.empty?

        @propagation_scope_snapshot ||= Execution::ScopeSnapshot.new(execution: execution, owned: true)
      end

      def linked_propagation_scope_snapshot
        return unless linked_propagation?

        @linked_propagation_scope_snapshot ||= Execution::ScopeSnapshot.new(
          execution: propagation_execution_hash,
          owned: true
        )
      end

      def invalidate_propagation_cache!
        @propagation_execution_hash = nil
        @propagation_scope_snapshot = nil
        @linked_propagation_scope_snapshot = nil
      end

      def linked_propagation?
        @execution_overlays.reverse_each.find { |overlay| !overlay.execution.empty? }&.link_executions
      end

      def merged_execution_hash(execution, owned:)
        return Fields::FieldSet.merge!(inherited_execution_hash, execution) unless owned

        Serialization::DeepFreeze.validate_symbol_hash(execution)
        Fields::Internal.merge_owned!(inherited_execution_hash, execution)
      end

      def inherited_execution_hash
        scope = current_scope
        return execution_hash unless scope

        Fields::Internal.merge_owned!(scope.inheritable_execution_hash, execution_hash)
      end

      def finish_scope(scope, on_finish, on_finish_failure, active_exception: nil)
        return unless on_finish

        contain_finish_failure(on_finish_failure, active_exception, phase: :summary_finish) do
          scope.finish_owned unless scope.finished?
        end
        contain_finish_failure(on_finish_failure, active_exception, phase: :summary_emit) { on_finish.call(scope) }
      end

      def contain_finish_failure(on_finish_failure, active_exception, phase:)
        yield
      rescue StandardError => e
        report_finish_failure(on_finish_failure, e, phase: phase)
      rescue SystemStackError => e
        # Preserve the app's active stack error during unwind.
        raise unless active_exception

        report_finish_failure(on_finish_failure, e, phase: phase)
      end

      def report_finish_failure(on_finish_failure, error, phase:)
        on_finish_failure.call(error, phase: phase)
      rescue StandardError
        nil
      end
    end
  end
end
