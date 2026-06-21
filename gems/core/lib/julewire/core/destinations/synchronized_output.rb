# frozen_string_literal: true

module Julewire
  module Core
    module Destinations
      class SynchronizedOutput
        def initialize(output, close_output: false)
          Sink.validate_writeable!(output)
          @output = output
          @close_output = close_output
          @mutex = Mutex.new
        end

        def after_fork!
          @mutex = Mutex.new
          @output.after_fork! if @output.respond_to?(:after_fork!)
          self
        end

        def output_class_name = @output.class.name

        def resource_identity = @output

        def write(value)
          @mutex.synchronize { @output.write(value) }
        end

        def flush
          @mutex.synchronize do
            return true unless @output.respond_to?(:flush)

            @output.flush != false
          end
        end

        def close
          @mutex.synchronize do
            return true if output_closed?

            result = if @close_output && @output.respond_to?(:close)
                       @output.close
                     elsif @output.respond_to?(:flush)
                       @output.flush
                     end
            result != false
          end
        end

        private

        def output_closed?
          @output.respond_to?(:closed?) ? @output.closed? : false
        end
      end
    end
  end
end
