# frozen_string_literal: true

require "concurrent/atomic/atomic_reference"

module Julewire
  module Ractor
    # @api internal
    # Experimental bridge that forwards ractor records back to a parent runtime.
    module Bridge
      ENABLED = Concurrent::AtomicReference.new(false)
      private_constant :ENABLED

      class << self
        def opt_in!
          ENABLED.set(true)
        end

        def enabled? = ENABLED.get

        def start(args:, name:, runtime:, &)
          unless enabled?
            raise Core::Error, "Julewire.ractor is experimental; call Julewire.enable_experimental_ractor! first"
          end

          RuntimeValidation.validate!(runtime)

          envelope = Core::Propagation.capture_local
          body = ::Ractor.shareable_proc(&)
          port = ::Ractor::Port.new
          ractor = spawn_ractor(
            args: args,
            name: name,
            port: port,
            envelope: envelope,
            body: body,
            emit_non_standard_exception_summaries: runtime.config.emit_non_standard_exception_summaries
          )
          start_bridge(port: port, runtime: runtime, ractor: ractor)
          ractor
        end

        def health = Stats.health

        def reset!
          ENABLED.set(false)
          Stats.reset!
        end

        def after_fork! = Stats.after_fork!

        def before_fork!
          active_bridges = health.fetch(:active_threads)
          if active_bridges.positive?
            raise UnsafeForkError,
                  "cannot fork while #{active_bridges} Julewire ractor bridge thread(s) are active"
          end

          return if ::Ractor.count.eql?(1)

          raise UnsafeForkError, "cannot fork while non-main Ractors are active"
        end

        private

        def start_bridge(port:, runtime:, ractor: nil)
          monitor_port = monitor_ractor(ractor)
          BridgeThread.start(port: port, monitor_port: monitor_port) { handle_message(runtime, it) }
        end

        def monitor_ractor(ractor)
          return unless ractor

          monitor_port = ::Ractor::Port.new
          return unless monitor_port.instance_of?(::Ractor::Port)

          ractor.monitor(monitor_port)
          monitor_port
        rescue StandardError
          nil
        end

        def spawn_ractor(args:, name:, port:, envelope:, body:, emit_non_standard_exception_summaries:)
          # simplecov:disable
          ::Ractor.new(port, envelope, body, emit_non_standard_exception_summaries, *args, name: name) do
            |bridge_port, captured_envelope, callable, emit_non_standard_summaries, *call_args|
            Core::RuntimeLocator.current = RemoteRuntime.new(
              port: bridge_port, emit_non_standard_exception_summaries: emit_non_standard_summaries
            )
            Core::Propagation.restore(captured_envelope, owned: true) do
              callable.call(*call_args)
            end
          ensure
            # Tell the bridge thread to exit even when the child body raises.
            begin
              bridge_port.send({ command: :close })
            rescue StandardError
              nil
            end
          end
          # simplecov:enable
        end

        def handle_message(runtime, message)
          response = dispatch(runtime, message)
          reply_to(message, response)
        rescue StandardError => e
          Stats.message_failed(e)
          reply_to(message, nil)
        end

        def dispatch(runtime, message)
          validate_message!(message)
          command = message.fetch(:command)
          case command
          when :emit
            dispatch_emit(runtime, message, enforce_level: true)
          when :emit_without_level
            dispatch_emit(runtime, message, enforce_level: false)
          when :emit_record
            runtime.emit_summary_record(
              RemoteSummaryRecord.new(RemotePayload.hash_value(message, :payload))
            )
          when :flush
            runtime.flush(timeout: message.fetch(:payload).fetch(:timeout))
          else
            raise ArgumentError, "unknown ractor bridge command: #{command.inspect}"
          end
        end

        def dispatch_emit(runtime, message, enforce_level:)
          payload = RemotePayload.hash_value(message, :payload)
          arguments = RemotePayload.extract(payload)
          arguments[:enforce_level] = false unless enforce_level
          runtime.emit_envelope(**arguments, owned: true)
        end

        def reply_to(message, response)
          return unless message.is_a?(Hash)

          reply = message[:reply]
          return unless reply

          raise TypeError, "ractor bridge reply must be a Ractor::Port" unless reply_port?(reply)

          reply.send(response)
        rescue StandardError => e
          Stats.message_failed(e)
          nil
        end

        def reply_port?(reply)
          reply.is_a?(::Ractor::Port)
        end

        def validate_message!(message)
          Core::Integration::Protocol.validate_symbol_hash(message)
        end
      end
    end
  end
end
