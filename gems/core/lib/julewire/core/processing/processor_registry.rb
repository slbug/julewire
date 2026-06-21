# frozen_string_literal: true

module Julewire
  module Core
    module Processing
      class ProcessorRegistry
        Entry = Data.define(:entry, :arguments, :options, :on_error, :factory)

        def initialize(entries = [])
          @entries = entries.map { normalize_entry(it) }
        end

        def use(processor = nil, *arguments, **options, &block)
          add(resolve_processor(processor, block), arguments, options, prepend: false)
        end

        def prepend(processor = nil, *arguments, **options, &block)
          add(resolve_processor(processor, block), arguments, options, prepend: true)
        end

        def clear
          @entries.clear
          self
        end

        def to_a
          @entries.map { materialize(it) }
        end

        def copy
          self.class.new(@entries)
        end

        def freeze
          @entries.freeze
          super
        end

        private

        def resolve_processor(processor, block)
          raise ArgumentError, "pass processor or block, not both" if processor && block

          processor || block
        end

        def add(processor, arguments, options, prepend:)
          raise ArgumentError, "processor or block is required" unless processor

          entry = build_entry(processor, arguments, options)
          prepend ? @entries.unshift(entry) : @entries << entry
          self
        end

        def build_entry(processor, arguments = [], options = {})
          options = options.dup
          on_error = ProcessorWrapper.normalize_policy(
            options.delete(:on_error) { ProcessorWrapper::FAIL_CLOSED }
          )

          if factory_processor?(processor)
            Entry.new(
              entry: processor.to_sym,
              arguments: arguments.dup.freeze,
              options: options.freeze,
              on_error: on_error,
              factory: true
            )
          elsif processor.is_a?(Class)
            Entry.new(
              entry: processor,
              arguments: arguments.dup.freeze,
              options: options.freeze,
              on_error: on_error,
              factory: false
            )
          else
            validate_processor_object!(processor, arguments, options)
            Entry.new(entry: processor, arguments: [].freeze, options: {}.freeze, on_error: on_error, factory: false)
          end
        end

        def normalize_entry(entry)
          entry.is_a?(Entry) ? entry : build_entry(entry)
        end

        def materialize(entry)
          processor = if entry.factory
                        Processing.build(entry.entry, *entry.arguments, **entry.options)
                      elsif entry.entry.is_a?(Class)
                        entry.entry.new(*entry.arguments, **entry.options)
                      else
                        entry.entry
                      end
          ProcessorWrapper.new(processor, on_error: entry.on_error)
        end

        def factory_processor?(processor)
          processor.respond_to?(:to_sym) && Processing.factory_for(processor)
        end

        def validate_processor_object!(processor, arguments, options)
          raise ArgumentError, "unknown processor kind #{processor.to_sym.inspect}" if processor.respond_to?(:to_sym)

          raise ArgumentError, "processor constructor arguments require a class" unless arguments.empty?
          raise ArgumentError, "processor options require a class" unless options.empty?

          return if processor.respond_to?(:call)

          raise ArgumentError, "processor must respond to call"
        end
      end
    end
  end
end
