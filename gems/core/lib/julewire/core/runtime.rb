# frozen_string_literal: true

require "concurrent/atomic/atomic_reference"
require "concurrent/atomic/atomic_fixnum"

module Julewire
  module Core
    class Runtime # rubocop:disable Metrics/ClassLength
      CONFIGURE_GUARD_KEY = :__julewire_core_configure_guard__
      RUNTIME_COUNTER_KEYS = %i[
        close_attempts
        configure_attempts
        flush_attempts
        lifecycle_warnings
        post_close_emits_total
        reset_attempts
        runtime_callback_failures
        runtime_failures
      ].freeze
      CloseTransition = Data.define(:state, :close_pipeline, :timeout)
      PipelineReplacement = Data.define(
        :old_pipeline,
        :close_timeout,
        :old_on_failure,
        :close_pipeline,
        :retained_resources
      )
      ResetTransition = Data.define(:old_pipeline, :close_timeout, :old_on_failure, :close_pipeline)

      def initialize
        @configure_mutex = Mutex.new
        @configure_generation = Concurrent::AtomicFixnum.new(0)
        @state_mutex = Mutex.new
        @post_close_emit_count = Concurrent::AtomicFixnum.new(0)
        @runtime_health = build_runtime_health
        @integration_health = Diagnostics::IntegrationHealthStore.new
        @invalid_severity_reporter = Diagnostics::InvalidSeverityReporter.counter
        @state_ref = Concurrent::AtomicReference.new(
          RuntimeState.default(invalid_severity_reporter: @invalid_severity_reporter)
        )
        @execution_boundary = build_execution_boundary
      end

      def config = runtime_state.configuration

      def labels = config.labels

      def attributes = ContextStore.current.attributes_proxy

      def carry = ContextStore.current.carry_proxy

      def context = ContextStore.current.context_proxy

      def summary = ContextStore.current.summary_proxy

      def current_execution
        scope = ContextStore.current.current_scope
        scope && Execution::View.new(scope)
      end

      def current_execution?
        ContextStore.current.current_scope?
      end

      def with_execution(...) = @execution_boundary.with_execution(...)

      def start_execution(...) = @execution_boundary.start_execution(...)

      def emit(record = Core::UNSET, **fields, &)
        emit_with_level_check(record, true, fields, &)
      end

      def emit_without_level(record = Core::UNSET, **fields, &)
        emit_with_level_check(record, false, fields, &)
      end

      def emit_integration(record, enforce_level: true)
        with_emit_guard(:emit_integration) do |state|
          state.pipeline.emit_integration(record, enforce_level: enforce_level)
        end
      end

      def emit_envelope(input:, context:, scope:, carry: {}, attributes: {}, neutral: {}, enforce_level: true)
        reject_runtime_call_during_configure!(:emit_envelope)
        state = runtime_state
        return record_post_close_emit(state) if state.pipeline_closed

        begin
          record = Records::Draft.build(
            input,
            context: envelope_hash(context),
            attributes: envelope_hash(attributes),
            neutral: envelope_hash(neutral),
            carry: envelope_hash(carry),
            scope: scope,
            error_backtrace_lines: state.configuration.error_backtrace_lines,
            invalid_severity_reporter: @invalid_severity_reporter
          ).to_record
          state.pipeline.emit_record(record, enforce_level: enforce_level)
        rescue StandardError => e
          notify_failure(e, state, action: :emit_envelope)
          nil
        end
      end

      def emit_summary_record(scope)
        reject_runtime_call_during_configure!(:emit_summary_record)
        state = runtime_state
        return record_post_close_emit(state) if state.pipeline_closed

        begin
          input = scope.owned_summary_record_input
          state.pipeline.emit_isolated_input(input)
        rescue StandardError => e
          notify_failure(e, state, action: :emit_summary_record)
          nil
        end
      end

      def configure(&)
        raise ArgumentError, "Julewire.configure requires a block" unless block_given?

        increment_runtime_count(:configure_attempts)
        replacement = build_configured_pipeline(&)
        deadline = Scheduling::Deadline.for(replacement.close_timeout)
        if replacement.close_pipeline
          report_pipeline_close_result(
            replacement.old_pipeline,
            timeout: Scheduling::Deadline.remaining(deadline),
            on_failure: replacement.old_on_failure,
            operation: :configure,
            skip_resource_identities: replacement.retained_resources
          )
        end
        config
      end

      def flush(timeout: Core::UNSET)
        call_validated_lifecycle(:flush, timeout)
      end

      def close(timeout: Core::UNSET)
        close_state_resources(close_state(timeout))
      end

      def reset!
        increment_runtime_count(:reset_attempts)
        reset_result = reject_runtime_call_during_configure!(:reset!) do
          @configure_mutex.synchronize do
            @state_mutex.synchronize { reset_under_lock }
          end
        end
        deadline = Scheduling::Deadline.for(reset_result.close_timeout)
        return unless reset_result.close_pipeline

        report_pipeline_close_result(
          reset_result.old_pipeline,
          timeout: Scheduling::Deadline.remaining(deadline),
          on_failure: reset_result.old_on_failure,
          operation: :reset
        )
      end

      def after_fork!
        reject_runtime_call_during_configure!(:after_fork!)
        RuntimeRegistry.reset_after_fork(primary: self)
      end

      def reset_after_fork_runtime!
        reset_after_fork_state!
        runtime_state.pipeline.after_fork!
        self
      end

      def record_integration_failure(integration, error, **metadata)
        @integration_health.record_failure(integration, error, **metadata)
      end

      def record_integration_success(integration)
        @integration_health.record_success(integration)
      end

      def health
        state = runtime_state
        pipeline_health = state.pipeline.health
        integrations = @integration_health.health
        process_integrations = Diagnostics::ProcessIntegrationHealth.health
        {
          closed: state.pipeline_closed,
          counts: runtime_counts_snapshot,
          generation: state.pipeline_generation,
          integrations: integrations,
          last_callback_failure: @runtime_health.last_callback_failure,
          last_failure: @runtime_health.last_failure,
          pipeline: pipeline_health,
          process_integrations: process_integrations,
          status: runtime_status(state, pipeline_health, integrations, process_integrations)
        }
      end

      private

      def before_execution_boundary_call!(action)
        reject_runtime_call_during_configure!(action)
      end

      def runtime_state = @state_ref.get

      def build_configured_pipeline(&)
        reject_runtime_call_during_configure!(:configure) do
          with_configure_guard do
            @configure_mutex.synchronize { configure_transaction(&) }
          end
        end
      end

      def configure_transaction
        state = runtime_state
        next_configuration_builder = state.configuration.copy
        yield next_configuration_builder
        next_configuration = next_configuration_builder.snapshot
        next_pipeline = next_configuration.build_pipeline(invalid_severity_reporter: @invalid_severity_reporter)

        install_and_replace_pipeline(state, next_configuration, next_pipeline)
      end

      def install_and_replace_pipeline(state, next_configuration, next_pipeline)
        replaced_pipeline = @state_mutex.synchronize do
          raise Error, "Julewire.configure state changed before install completed" unless runtime_state.equal?(state)

          replace_pipeline(next_configuration, next_pipeline)
        end
        PipelineReplacement.new(
          replaced_pipeline,
          state.configuration.pipeline_close_timeout,
          state.configuration.on_failure,
          !state.pipeline_closed,
          next_pipeline.lifecycle_resource_identities
        )
      rescue StandardError
        next_pipeline.close(timeout: next_configuration.pipeline_close_timeout)
        raise
      end

      def with_configure_guard
        previous = Fiber[CONFIGURE_GUARD_KEY]
        Fiber[CONFIGURE_GUARD_KEY] = [object_id, @configure_generation.increment]
        yield
      ensure
        @configure_generation.increment
        Fiber[CONFIGURE_GUARD_KEY] = previous
      end

      def replace_pipeline(configuration, pipeline)
        state = runtime_state
        @post_close_emit_count.value = 0
        @runtime_health.clear_degradation
        @state_ref.set(state.next_generation(configuration: configuration, pipeline: pipeline))
        state.pipeline
      end

      def call_validated_lifecycle(method_name, timeout)
        degradation_marker = @runtime_health.degradation_marker
        reject_runtime_call_during_configure!(method_name)
        state = runtime_state
        timeout = normalize_lifecycle_timeout(timeout, state)
        validate_lifecycle_timeout!(timeout, name: :timeout)
        increment_lifecycle_attempt(method_name)
        return true if state.pipeline_closed

        result = call_pipeline_lifecycle_on(state.pipeline, method_name, timeout: timeout, state: state)
        clear_runtime_degradation_if_unchanged(degradation_marker) unless result == false
        result
      end

      def normalize_lifecycle_timeout(timeout, state)
        timeout.equal?(Core::UNSET) ? state.configuration.pipeline_close_timeout : timeout
      end

      def validate_lifecycle_timeout!(timeout, name:)
        Validation.validate_timeout!(timeout, name: name)
      end

      def close_state_resources(transition)
        return true unless transition.close_pipeline

        deadline = Scheduling::Deadline.for(transition.timeout)
        call_pipeline_lifecycle_on(
          transition.state.pipeline,
          :close,
          timeout: Scheduling::Deadline.remaining(deadline),
          state: transition.state
        )
      end

      def close_state(timeout)
        reject_runtime_call_during_configure!(:close)
        @state_mutex.synchronize do
          state = runtime_state
          timeout = normalize_lifecycle_timeout(timeout, state)
          validate_lifecycle_timeout!(timeout, name: :timeout)
          increment_runtime_count(:close_attempts)
          close_pipeline = !state.pipeline_closed
          return CloseTransition.new(state, false, timeout) unless close_pipeline

          @state_ref.set(state.closed)
          CloseTransition.new(state, close_pipeline, timeout)
        end
      end

      def call_pipeline_lifecycle_on(pipeline, method_name, timeout:, state:)
        pipeline.public_send(method_name, timeout: timeout)
      rescue StandardError => e
        notify_failure(e, state, action: method_name)
        false
      end

      def emit_with_level_check(record, enforce_level, fields, &)
        with_emit_guard(:emit) do |state|
          if enforce_level
            state.pipeline.emit(record, **fields, &)
          else
            state.pipeline.emit_without_level(record, **fields, &)
          end
        end
      end

      def with_emit_guard(action)
        degradation_marker = @runtime_health.degradation_marker
        reject_runtime_call_during_configure!(action)
        state = runtime_state
        return record_post_close_emit(state) if state.pipeline_closed

        begin
          yield state
          clear_runtime_degradation_if_unchanged(degradation_marker)
          nil
        rescue StandardError => e
          notify_failure(e, state, action: action)
          nil
        end
      end

      def envelope_hash(value)
        value.is_a?(Hash) ? value : {}
      end

      def record_post_close_emit(state)
        @post_close_emit_count.increment
        increment_runtime_count(:post_close_emits_total)
        metadata = { phase: :runtime, reason: :runtime_closed }
        callback_result = Diagnostics::CallbackNotifier.call(state.configuration.on_drop, :runtime_closed, metadata)
        if Diagnostics::CallbackNotifier.failure?(callback_result)
          @runtime_health.record_callback_failure(callback_result)
        end
        nil
      end

      def runtime_status(state, pipeline_health, integrations, process_integrations)
        return :closed if state.pipeline_closed

        runtime_degraded?(pipeline_health, integrations, process_integrations) ? :degraded : :ok
      end

      def runtime_degraded?(pipeline_health, integrations, process_integrations)
        @runtime_health.degraded? ||
          pipeline_degraded?(pipeline_health) ||
          integrations_degraded?(process_integrations) ||
          integrations_degraded?(integrations)
      end

      def pipeline_degraded?(pipeline_health)
        return true if pipeline_health[:status] && pipeline_health[:status] != :ok

        pipeline_health.fetch(:destinations).values.any? do |destination_health|
          destination_health[:status] && destination_health[:status] != :ok
        end
      end

      def integrations_degraded?(integrations)
        integrations.values.any? do |integration_health|
          integration_health[:status] && integration_health[:status] != :ok
        end
      end

      def clear_runtime_degradation_if_unchanged(marker)
        @runtime_health.clear_degradation_if_unchanged(marker)
      end

      def summary_finalizer_failure
        @summary_finalizer_failure ||= ->(error) { handle_summary_finalizer_failure(error) }
      end

      def reset_after_fork_state!
        state = runtime_state
        @configure_mutex = Mutex.new
        @configure_generation = Concurrent::AtomicFixnum.new(0)
        @state_mutex = Mutex.new
        @post_close_emit_count = Concurrent::AtomicFixnum.new(0)
        @runtime_health = build_runtime_health
        @integration_health.after_fork!
        @invalid_severity_reporter.reset_after_fork!
        @state_ref = Concurrent::AtomicReference.new(state)
        nil
      end

      def reset_under_lock
        state = runtime_state
        configuration = Configuration.new.snapshot
        @invalid_severity_reporter.reset!
        next_pipeline = configuration.build_pipeline(invalid_severity_reporter: @invalid_severity_reporter)
        replace_pipeline(configuration, next_pipeline)
        ContextStore.reset_current!
        @post_close_emit_count.value = 0
        @runtime_health.clear_failures!
        @integration_health.reset!
        Diagnostics::ProcessIntegrationHealth.reset!
        Diagnostics::InvalidSeverityReporter.reset!
        ResetTransition.new(
          state.pipeline,
          state.configuration.pipeline_close_timeout,
          state.configuration.on_failure,
          !state.pipeline_closed
        )
      end

      def reject_runtime_call_during_configure!(method_name)
        if configure_guard_active?
          raise Error, "Julewire.#{method_name} cannot be called from inside Julewire.configure"
        end

        block_given? ? yield : nil
      end

      def configure_guard_active?
        token = Fiber[CONFIGURE_GUARD_KEY]
        token.is_a?(Array) && token.fetch(0) == object_id && token.fetch(1) == @configure_generation.value
      end

      def increment_lifecycle_attempt(method_name)
        increment_runtime_count(:"#{method_name}_attempts")
      end

      def increment_runtime_count(key)
        @runtime_health.increment(key)
      end

      def runtime_counts_snapshot
        @runtime_health.counts.merge(
          invalid_record_severities: @invalid_severity_reporter.health.fetch(:count),
          post_close_emits: @post_close_emit_count.value
        )
      end

      def notify_failure(error, state, **metadata)
        metadata = { phase: :runtime }.merge(metadata)
        @runtime_health.record_failure(error, callback: state.configuration.on_failure, **metadata)
      end

      def handle_summary_finalizer_failure(error)
        state = runtime_state
        metadata = { phase: :summary_finalizer }
        @runtime_health.record_failure(error, callback: state.configuration.on_failure, **metadata)
      end

      def report_pipeline_close_result(pipeline, timeout:, on_failure:, operation:, skip_resource_identities: nil)
        return unless pipeline.close(timeout: timeout, skip_resource_identities: skip_resource_identities) == false

        notify_lifecycle_warning(
          record_lifecycle_warning(
            LifecycleError.new("Julewire pipeline close returned false"),
            on_failure: on_failure,
            action: :close,
            operation: operation,
            phase: :pipeline_teardown,
            timeout: timeout
          )
        )
      end

      def record_lifecycle_warning(error, on_failure:, **metadata)
        increment_runtime_count(:lifecycle_warnings)
        { error: error, metadata: metadata, on_failure: on_failure }
      end

      def notify_lifecycle_warning(warning)
        return unless warning

        result = Diagnostics::CallbackNotifier.call(warning.fetch(:on_failure), warning.fetch(:error),
                                                    warning.fetch(:metadata))
        @runtime_health.record_callback_failure(result) if Diagnostics::CallbackNotifier.failure?(result)
      end

      def build_runtime_health
        Diagnostics::Health.new(
          counter_keys: RUNTIME_COUNTER_KEYS,
          callback_metadata: {},
          callback_failure_counter: :runtime_callback_failures,
          failure_counter: :runtime_failures
        )
      end

      def emit_non_standard_exception_summaries? = runtime_state.configuration.emit_non_standard_exception_summaries

      def build_execution_boundary
        Execution::Boundary.new(
          before_call: ->(action) { before_execution_boundary_call!(action) },
          emit_summary_record: ->(scope) { emit_summary_record(scope) },
          summary_finalizer_failure: summary_finalizer_failure,
          emit_non_standard_exception_summaries: -> { emit_non_standard_exception_summaries? }
        )
      end
    end
  end
end
