# frozen_string_literal: true

require "zeitwerk"
require "julewire/core"

module Julewire
  module Ractor
    class << self
      def health
        bridge_health
      end

      def child_stats
        child_runtime&.child_stats || {}
      end

      def reset_child_stats!
        child_runtime&.reset_child_stats!
      end

      def fanout(destinations:, **)
        Fanout.new(destinations: destinations, **)
      end

      def enable_default_destination_workers!
        Core::Destinations.register(:default) { |name:, **options| Destination.new(name: name, **options) }
        nil
      end

      private

      def bridge_health
        Bridge.health
      end

      def child_runtime
        runtime = Core::RuntimeLocator.current
        runtime if runtime.respond_to?(:child_stats)
      end
    end
  end

  loader = Zeitwerk::Loader.for_gem_extension(self)
  loader.setup
  Core::Destinations.register(:ractor) { |name:, **options| Ractor::Destination.new(name: name, **options) }
  Core::Integration::Lifecycle.register_after_fork(:ractor, component: :bridge) { Ractor::Bridge.after_fork! }

  class << self
    def enable_experimental_ractor!
      Ractor::Bridge.opt_in!
    end

    def ractor(*args, name: nil, &block)
      raise ArgumentError, "block required" unless block

      Ractor::Bridge.spawn(args: args, name: name, runtime: Core::RuntimeLocator.current, &block)
    end
  end
end
