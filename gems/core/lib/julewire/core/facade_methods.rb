# frozen_string_literal: true

module Julewire
  module Core
    module FacadeMethods
      def runtime(name = :default)
        Core::RuntimeRegistry.fetch(name, current: Core::RuntimeLocator.current)
      end

      def config = runtime.config

      def configure(&) = runtime.configure(&)

      def context = runtime.context

      def attributes = runtime.attributes

      def carry = runtime.carry

      def current_execution = runtime.current_execution

      def current_execution? = runtime.current_execution?

      def emit(record = Core::UNSET, **fields, &)
        runtime.emit(record, **fields, &)
      end

      def debug(record = Core::UNSET, **fields, &)
        emit_with_severity(:debug, record, fields, &)
      end

      def info(record = Core::UNSET, **fields, &)
        emit_with_severity(:info, record, fields, &)
      end

      def warn(record = Core::UNSET, **fields, &)
        emit_with_severity(:warn, record, fields, &)
      end

      def error(record = Core::UNSET, **fields, &)
        emit_with_severity(:error, record, fields, &)
      end

      def fatal(record = Core::UNSET, **fields, &)
        emit_with_severity(:fatal, record, fields, &)
      end

      def unknown(record = Core::UNSET, **fields, &)
        emit_with_severity(:unknown, record, fields, &)
      end

      def flush(timeout: Core::UNSET)
        runtime.flush(timeout: timeout)
      end

      def health = runtime.health

      def measure(key, &)
        summary.measure(key, &)
      end

      def measure_start(key) = summary.measure_start(key)

      def doctor(name = :default)
        Core::Diagnostics::Doctor.call(runtime(name))
      end

      def tail(name = :default, **)
        Core::Diagnostics::Tail.attach!(runtime(name), **)
      end

      def observe_self!(name = :default, **)
        Core::Diagnostics::MetaObserver.attach!(name, **)
      end

      def dev!(name = :default, output: $stdout, color: Core::UNSET, chaos: false, banner: chaos, tail: true)
        color = output.respond_to?(:tty?) ? output.tty? : true if color.equal?(Core::UNSET)
        punk!(name, output: output, color: color, chaos: chaos, banner: banner)
        return unless tail

        tail_options = tail == true ? {} : tail
        raise ArgumentError, "tail must be true, false, or an options Hash" unless tail_options.is_a?(Hash)

        Core::Diagnostics::Tail.attach!(runtime(name), **tail_options)
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

        envelope = Core::Propagation.capture_local
        Fiber.new(**) do |*args|
          with_cleared_configure_guard do
            Core::Propagation.restore(envelope, owned: true) { yield(*args) }
          end
        end
      end

      def labels = runtime.labels

      def after_fork! = runtime.after_fork!

      def reset! = runtime.reset!

      def close(timeout: Core::UNSET)
        runtime.close(timeout: timeout)
      end

      def summary = runtime.summary

      def start_execution(type:, **)
        runtime.start_execution(type: type, **)
      end

      def thread(*, &)
        raise ArgumentError, "block required" unless block_given?

        envelope = Core::Propagation.capture_local
        Thread.new(*) do |*thread_args|
          with_cleared_configure_guard do
            Core::Propagation.restore(envelope, owned: true) { yield(*thread_args) }
          end
        end
      end

      def with_execution(type:, **, &)
        runtime.with_execution(type: type, **, &)
      end

      private

      def punk_banner
        "!!JULEWIRE PUNK!! chaos containment armed\n"
      end

      def punk_chaos_output(output, chaos)
        options = chaos.is_a?(Hash) ? chaos : {}
        Core::Destinations::ChaosOutput.new(output, **options)
      end

      def emit_with_severity(severity, record, fields, &)
        if record.equal?(Core::UNSET)
          fields.delete("severity")
          fields[:severity] = severity
          runtime.emit(fields, &)
        elsif !block_given? && !record.is_a?(Hash)
          # Scalar eager logs stay allocation-light; lazy inputs need the wrapper
          # so block-built records can still receive the eager severity.
          input = fields.empty? ? { message: record.to_s } : Core.emit_input(record, fields)
          input.delete("severity")
          input[:severity] = severity
          runtime.emit(input)
        else
          runtime.emit(Core::Records::LazyEmitInput.with_severity(severity, Core.emit_input(record, fields)), &)
        end
      end

      def with_cleared_configure_guard
        previous_guard = Fiber[Core::Runtime::CONFIGURE_GUARD_KEY]
        Fiber[Core::Runtime::CONFIGURE_GUARD_KEY] = nil
        yield
      ensure
        Fiber[Core::Runtime::CONFIGURE_GUARD_KEY] = previous_guard
      end
    end
  end
end
