# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      module Chaos
        class Catalog
          Entry = Data.define(:kind, :name, :exercise)
          KINDS = %i[processor formatter encoder destination subscriber listener].freeze

          attr_reader :entries

          class << self
            def build
              catalog = new
              yield catalog if block_given?
              catalog
            end

            def assert_contract(test_context, catalog:, errors:)
              entries = catalog.entries
              raise ArgumentError, "chaos catalog must have entries" if entries.empty?

              entries.each do |entry|
                assert_entry(test_context, entry, errors)
              end
              nil
            end

            private

            def assert_entry(test_context, entry, errors)
              Chaos.assert_contained(
                test_context,
                errors: errors,
                description: "#{entry.kind} #{entry.name}"
              ) do |error|
                entry.exercise.call(error)
              end
            end
          end

          def initialize
            @entries = []
          end

          def processor(name, &) = register(:processor, name, &)

          def formatter(name, &) = register(:formatter, name, &)

          def encoder(name, &) = register(:encoder, name, &)

          def destination(name, &) = register(:destination, name, &)

          def subscriber(name, &) = register(:subscriber, name, &)

          def listener(name, &) = register(:listener, name, &)

          private

          def register(kind, name, &exercise)
            raise ArgumentError, "unknown chaos component kind #{kind.inspect}" unless KINDS.include?(kind)
            raise ArgumentError, "chaos component exercise block required" unless exercise

            @entries << Entry.new(kind, Core.normalize_name(name), exercise)
            self
          end
        end
      end
    end
  end
end
