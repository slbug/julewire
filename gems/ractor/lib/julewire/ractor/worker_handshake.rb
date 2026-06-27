# frozen_string_literal: true

module Julewire
  module Ractor
    class WorkerHandshake
      DEFAULT_TIMEOUT = 1

      class << self
        def receive(setup_port:, worker:, scheduler:, timeout: DEFAULT_TIMEOUT)
          PortLifecycle.with_port do |timeout_port|
            scheduler.with_timeout(timeout_port, timeout: timeout) do
              selected, value = ::Ractor.select(setup_port, worker, timeout_port)

              if selected.equal?(timeout_port)
                raise Core::Error, "ractor destination worker did not start within #{timeout} seconds"
              end
              return value if selected.equal?(setup_port) && value.is_a?(::Ractor::Port)

              raise ArgumentError, "ractor destination worker did not start"
            end
          end
        end
      end
    end

    private_constant :WorkerHandshake
  end
end
