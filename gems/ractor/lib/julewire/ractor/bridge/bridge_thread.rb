# frozen_string_literal: true

module Julewire
  module Ractor
    module Bridge
      module BridgeThread
        THREAD_NAME = "julewire-ractor-bridge"
        MONITOR_MESSAGES = %i[aborted exited].freeze

        class << self
          def start(port:, monitor_port: nil, &handler)
            Thread.new { run(port: port, monitor_port: monitor_port, handler: handler) }.tap do |thread|
              thread.name = THREAD_NAME
              thread.report_on_exception = true
            end
          end

          def run(port:, handler:, monitor_port: nil)
            bridge_error = nil
            Stats.bridge_started
            loop do
              message = receive_message(port, monitor_port)
              Stats.message_received
              break if close_message?(message) || monitor_message?(message)

              handler.call(message)
            rescue StandardError => e
              bridge_error = e
              warn_bridge_stopped(e)
              Julewire::Ractor::PortLifecycle.close(port)
              break
            end
          ensure
            Stats.bridge_stopped(bridge_error)
          end

          def close_message?(message)
            message.is_a?(Hash) && message[:command] == :close
          end

          def monitor_message?(message)
            MONITOR_MESSAGES.include?(message)
          end

          def receive_message(port, monitor_port)
            return port.receive unless monitor_port

            _selected_port, message = ::Ractor.select(port, monitor_port)
            message
          end

          def warn_bridge_stopped(error)
            Warning.warn("julewire ractor bridge stopped: #{error.class}\n")
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
