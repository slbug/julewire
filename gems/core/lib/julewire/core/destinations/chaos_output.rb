# frozen_string_literal: true

module Julewire
  module Core
    module Destinations
      class ChaosOutput
        MODES = %i[mixed raise reject sleep].freeze
        DEFAULT_RATE = 0.1
        DEFAULT_SLEEP_MS = 10

        def initialize(output, rate: DEFAULT_RATE, mode: :mixed, sleep_ms: DEFAULT_SLEEP_MS, seed: nil)
          Sink.validate_writeable!(output)
          @output = output
          @rate = validate_rate(rate)
          @mode = validate_mode(mode)
          @sleep_seconds = validate_sleep_ms(sleep_ms) / 1000.0
          @seed = seed
          @random = random
        end

        def write(value)
          return @output.write(value) unless trigger?

          case chaos_mode
          when :raise then raise "julewire punk chaos output failure"
          when :reject then false
          when :sleep
            sleep(@sleep_seconds)
            @output.write(value)
          end
        end

        def flush
          @output.flush if @output.respond_to?(:flush)
        end

        def close
          @output.close if @output.respond_to?(:close)
        end

        def closed?
          @output.closed? if @output.respond_to?(:closed?)
        end

        def after_fork!
          @random = random
          @output.after_fork! if @output.respond_to?(:after_fork!)
          self
        end

        def resource_identity = @output

        private

        def validate_rate(value)
          return value if finite_orderable_number?(value) && value.between?(0, 1)

          raise ArgumentError, "chaos rate must be a finite Numeric between 0 and 1"
        end

        def validate_mode(value)
          Validation.validate_symbol_choice!(value, name: "chaos mode", choices: MODES)
        end

        def validate_sleep_ms(value)
          return value if finite_orderable_number?(value) && value >= 0

          raise ArgumentError, "chaos sleep_ms must be a non-negative finite Numeric"
        end

        def finite_orderable_number?(value)
          value.is_a?(Numeric) && value.finite? && value.respond_to?(:between?)
        end

        def random
          @seed ? Random.new(@seed) : Random.new
        end

        def trigger?
          @rate.positive? && @random.rand < @rate
        end

        def chaos_mode
          return @mode unless @mode == :mixed

          %i[raise reject sleep].fetch(@random.rand(3))
        end
      end
    end
  end
end
