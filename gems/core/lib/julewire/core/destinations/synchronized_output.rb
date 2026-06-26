# frozen_string_literal: true

module Julewire
  module Core
    module Destinations
      class SynchronizedOutput
        TIMEOUT_PARAMETER_TYPES = %i[key keyreq].freeze
        private_constant :TIMEOUT_PARAMETER_TYPES

        def initialize(output, close_output: false)
          Sink.validate_writeable!(output)
          @output = output
          @close_output = close_output
          @mutex = Mutex.new
          @lifecycle_mutex = Mutex.new
          @lifecycle = lifecycle_methods
        end

        def after_fork!
          @mutex = Mutex.new
          @lifecycle_mutex = Mutex.new
          @output.after_fork! if @output.respond_to?(:after_fork!)
          @lifecycle = lifecycle_methods
          self
        end

        def output_class_name = @output.class.name

        def resource_identity = @output

        def write(value)
          @mutex.synchronize do
            return false if output_closed?

            @output.write(value)
          end
        end

        def flush(timeout: nil)
          @lifecycle_mutex.synchronize do
            lifecycle = @lifecycle[:flush]
            return true unless lifecycle

            call_lifecycle(:flush, lifecycle, timeout: timeout) != false
          end
        end

        def close(timeout: nil)
          @lifecycle_mutex.synchronize do
            # Close is terminal: lifecycle calls stay serialized, and the write mutex
            # keeps the underlying output from being closed while a write is in flight.
            @mutex.synchronize do
              return true if output_closed?

              result = if @close_output && @lifecycle[:close]
                         call_lifecycle(:close, @lifecycle.fetch(:close), timeout: timeout)
                       elsif @lifecycle[:flush]
                         call_lifecycle(:flush, @lifecycle.fetch(:flush), timeout: timeout)
                       end
              result != false
            end
          end
        end

        private

        def output_closed?
          @output.respond_to?(:closed?) ? @output.closed? : false
        end

        def call_lifecycle(name, lifecycle, timeout:)
          return @output.public_send(name, timeout: timeout) if lifecycle.fetch(:timeout)

          @output.public_send(name)
        end

        def lifecycle_methods
          %i[flush close].each_with_object({}) do |name, methods|
            next unless @output.respond_to?(name)

            method = @output.method(name)
            methods[name] = { timeout: accepts_timeout_keyword?(method) }.freeze
          end.freeze
        end

        def accepts_timeout_keyword?(method)
          method.parameters.any? { |type, name| TIMEOUT_PARAMETER_TYPES.include?(type) && name == :timeout } ||
            method.parameters.any? { |type, _name| type == :keyrest }
        end
      end
    end
  end
end
