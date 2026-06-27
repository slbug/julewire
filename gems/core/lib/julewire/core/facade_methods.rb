# frozen_string_literal: true

module Julewire
  module Core
    module FacadePrivateMethods
      private

      def punk_banner
        "!!JULEWIRE PUNK!! chaos containment armed\n"
      end

      def punk_chaos_output(output, chaos)
        options = chaos if chaos.is_a?(Hash)
        Destinations::ChaosOutput.new(output, **options)
      end

      def emit_with_severity(severity, record, fields, &)
        if !block_given? && !record.is_a?(Hash)
          # Scalar eager logs stay allocation-light; lazy inputs need the wrapper
          # so block-built records can still receive the eager severity.
          emit(eager_severity_input(severity, record, fields))
        else
          emit(Records::LazyEmitInput.with_severity(severity, Core.emit_input(record, fields)), &)
        end
      end

      def eager_severity_input(severity, record, fields)
        input = if record.equal?(UNSET)
                  fields
                elsif fields.empty?
                  { message: record.to_s }
                else
                  Core.emit_input(record, fields)
                end
        input.delete("severity")
        input[:severity] = severity
        input
      end

      def with_cleared_configure_guard
        previous_guard = Fiber[Runtime::CONFIGURE_GUARD_KEY]
        Fiber[Runtime::CONFIGURE_GUARD_KEY] = nil
        yield
      ensure
        Fiber[Runtime::CONFIGURE_GUARD_KEY] = previous_guard
      end
    end

    module FacadeMethods
      include FacadePrivateMethods

      def runtime(name = :default)
        RuntimeRegistry.fetch(name)
      end

      def config = runtime.config
      def configure(&) = runtime.configure(&)
      def context = runtime.context
      def attributes = runtime.attributes
      def carry = runtime.carry
      def current_execution = runtime.current_execution
      def current_execution? = runtime.current_execution?

      def emit(record = UNSET, **fields, &)
        runtime.emit(record, **fields, &)
      end

      def debug(record = UNSET, **fields, &)
        emit_with_severity(:debug, record, fields, &)
      end

      def info(record = UNSET, **fields, &)
        emit_with_severity(:info, record, fields, &)
      end

      def warn(record = UNSET, **fields, &)
        emit_with_severity(:warn, record, fields, &)
      end

      def error(record = UNSET, **fields, &)
        emit_with_severity(:error, record, fields, &)
      end

      def fatal(record = UNSET, **fields, &)
        emit_with_severity(:fatal, record, fields, &)
      end

      def unknown(record = UNSET, **fields, &)
        emit_with_severity(:unknown, record, fields, &)
      end

      def flush(timeout: UNSET)
        runtime.flush(timeout: timeout)
      end

      def health = runtime.health

      def measure(key, &)
        summary.measure(key, &)
      end

      def measure_start(key) = summary.measure_start(key)

      def doctor(name = :default)
        Diagnostics::Doctor.call(runtime(name))
      end

      def tail(name = :default, **)
        Diagnostics::Tail.attach!(runtime(name), **)
      end

      def observe_self!(name = :default, **)
        Diagnostics::MetaObserver.attach!(name, **)
      end

      def dev!(name = :default, output: $stdout, color: UNSET, chaos: false, banner: chaos, tail: true)
        color = output.respond_to?(:tty?) ? output.tty? : true if color.equal?(UNSET)
        punk!(name, output: output, color: color, chaos: chaos, banner: banner)
        return unless tail

        tail_options = tail == true ? {} : tail
        raise ArgumentError, "tail must be true, false, or an options Hash" unless tail_options.is_a?(Hash)

        Tail.attach!(runtime(name), **tail_options)
      end

      def punk!(name = :default, output: $stdout, color: true, chaos: false, banner: chaos)
        output.write(punk_banner) if banner
        output = punk_chaos_output(output, chaos) if chaos

        runtime(name).configure do |config|
          config.destinations.clear
          config.destinations.use(
            :default,
            formatter: ConsoleFormatter.new,
            encoder: TextEncoder.new(color: color, theme: :punk),
            output: output
          )
        end
      end

      def fiber(**, &)
        raise ArgumentError, "block required" unless block_given?

        envelope = Propagation.capture_local
        Fiber.new(**) do |*args|
          with_cleared_configure_guard do
            Propagation.restore(envelope, owned: true) { yield(*args) }
          end
        end
      end

      def labels = runtime.labels
      def after_fork! = runtime.after_fork!
      def reset! = runtime.reset_facade!

      def close(timeout: UNSET)
        runtime.close(timeout: timeout)
      end

      def summary = runtime.summary

      def start_execution(type:, **)
        runtime.start_execution(type: type, **)
      end

      def thread(*, &)
        raise ArgumentError, "block required" unless block_given?

        envelope = Propagation.capture_local
        Thread.new(*) do |*thread_args|
          with_cleared_configure_guard do
            Propagation.restore(envelope, owned: true) { yield(*thread_args) }
          end
        end
      end

      def with_execution(type:, **, &)
        runtime.with_execution(type: type, **, &)
      end
    end
  end
end
