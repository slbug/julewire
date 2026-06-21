# frozen_string_literal: true

module Julewire
  module Core
    # @api extension
    module Testing
      # @api extension
      class CaptureDestination
        attr_reader :name, :records

        def initialize(name: :capture, snapshot: true)
          @name = name
          @snapshot = snapshot
          @records = []
        end

        def emit(record)
          @records << (@snapshot ? record.to_h : record)
          nil
        end

        def flush(*)
          self
        end

        def close(*)
          self
        end

        def health
          { status: :ok, counts: { captured: @records.size } }
        end

        def clear
          @records.clear
          self
        end
      end

      # @api extension
      class NullOutput
        attr_reader :writes

        def initialize
          @writes = []
        end

        def write(value)
          @writes << value
          value.bytesize
        end

        def flush = self

        def close = self
      end

      class << self
        def configure_capture_destination(runtime = Julewire, **)
          destination = CaptureDestination.new(**)
          runtime.configure do |config|
            config.destinations.clear
            config.destinations.add(destination)
          end
          destination
        end

        def capture(runtime = Julewire, **)
          records = configure_capture_destination(runtime, **).records
          yield records if block_given?
          records
        end

        def unregister_destination(kind)
          Core::Destinations.__send__(:unregister, kind)
        end

        def reset_shared_scheduler
          Core::Scheduling::SharedScheduler.__send__(:reset_for_test!)
        end

        def with_overridden_singleton_method(receiver, method_name, replacement)
          singleton_class = class << receiver; self; end
          method_exists =
            singleton_class.method_defined?(method_name) || singleton_class.private_method_defined?(method_name)
          original = singleton_class.instance_method(method_name) if method_exists
          verbose = $VERBOSE
          $VERBOSE = nil
          singleton_class.define_method(method_name, replacement)
          yield
        ensure
          $VERBOSE = nil
          if original
            singleton_class.define_method(method_name, original)
          elsif singleton_class&.method_defined?(method_name) || singleton_class&.private_method_defined?(method_name)
            singleton_class.remove_method(method_name)
          end
          $VERBOSE = verbose
        end

        def nonblocking_queue_values(queue)
          values = []
          loop do
            values << queue.pop(true)
          rescue ThreadError
            return values
          end
        end
      end
    end
  end

  Testing = Core::Testing unless const_defined?(:Testing, false)
end

require_relative "testing/chaos"
require_relative "testing/chaos/catalog"
require_relative "testing/chaos/core_runtime"
require_relative "testing/chaos/destination"
require_relative "testing/chaos/emitter"
require_relative "testing/chaos/raising_output"
require_relative "testing/contracts"
