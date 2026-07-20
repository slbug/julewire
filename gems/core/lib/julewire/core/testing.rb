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

        def flush(*) = self
        def close(*) = self

        def health
          { status: :ok, counts: { captured: records.size } }
        end

        def clear
          records.clear
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
          writes << value
          value.bytesize
        end

        def flush = self
        def close = self
      end

      class << self
        def configure_capture_destination(runtime, **)
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
      end
    end
  end

  Testing = Core::Testing unless const_defined?(:Testing, false)
end
