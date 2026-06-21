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

        def spawn(args:, name:, runtime:, &)
          unless enabled?
            raise Core::Error, "Julewire.ractor is experimental; call Julewire.enable_experimental_ractor! first"
          end

          RuntimeValidation.validate!(runtime)

          envelope = Core::Propagation.capture
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

        private

        def start_bridge(port:, runtime:, ractor: nil)
          monitor_port = monitor_ractor(ractor)
          BridgeThread.start(port: port, monitor_port: monitor_port) { handle_message(runtime, it) }
        end

        def monitor_ractor(ractor)
          return unless ractor

          ::Ractor::Port.new.tap { ractor.monitor(it) }
        rescue StandardError
          nil
        end

        def spawn_ractor(args:, name:, port:, envelope:, body:, emit_non_standard_exception_summaries:)
          # :nocov:
          ::Ractor.new(port, envelope, body, emit_non_standard_exception_summaries, *args, name: name) do
            |bridge_port, captured_envelope, callable, emit_non_standard_summaries, *call_args|
            Julewire::Core::RuntimeLocator.current = Julewire::Ractor::RemoteRuntime.new(
              port: bridge_port, emit_non_standard_exception_summaries: emit_non_standard_summaries
            )
            Julewire::Core::Propagation.restore(captured_envelope) do
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
          # :nocov:
        end

        def handle_message(runtime, message)
          return unless message.is_a?(Hash)

          response = dispatch(runtime, message)
          reply_to(message, response)
        rescue StandardError => e
          Stats.message_failed(e)
          reply_to(message, nil)
        end

        def dispatch(runtime, message)
          case message[:command]
          when :emit
            dispatch_emit(runtime, message, enforce_level: true)
          when :emit_without_level
            dispatch_emit(runtime, message, enforce_level: false)
          when :emit_record
            runtime.emit_summary_record(
              RemoteSummaryRecord.new(RemotePayload.hash_value(message, :payload))
            )
          when :flush
            runtime.flush(timeout: message.dig(:payload, :timeout))
          end
        end

        def dispatch_emit(runtime, message, enforce_level:)
          payload = RemotePayload.hash_value(message, :payload)
          arguments = RemotePayload.extract(payload)
          arguments[:enforce_level] = false unless enforce_level
          runtime.emit_envelope(**arguments)
        end

        def reply_to(message, response)
          reply = message[:reply]
          reply.send(response) if reply_port?(reply)
        rescue StandardError => e
          Stats.message_failed(e)
          nil
        end

        def reply_port?(reply)
          reply.is_a?(::Ractor::Port)
        end
      end
    end
  end
end
