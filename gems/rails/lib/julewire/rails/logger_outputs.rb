# frozen_string_literal: true

require "active_support/logger"

module Julewire
  module Rails
    module LoggerOutputs
      class << self
        def install!
          return if @installed

          ::ActiveSupport::Logger.singleton_class.prepend(Patch)
          @installed = true
        end

        def julewire_logger?(logger)
          loggers = logger.respond_to?(:broadcasts) ? logger.broadcasts : [logger]
          loggers.any?(Logger)
        end

        def console_sources?(sources)
          sources.any? { it.equal?($stdout) || it.equal?($stderr) }
        end
      end

      module Patch
        def logger_outputs_to?(logger, *sources)
          return true if LoggerOutputs.julewire_logger?(logger) && LoggerOutputs.console_sources?(sources)

          super
        end
      end
      private_constant :Patch
    end
  end
end
