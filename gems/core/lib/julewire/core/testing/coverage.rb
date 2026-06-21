# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      # @api extension
      module Coverage
        DEFAULT_MINIMUM_LINE = 96
        DEFAULT_MINIMUM_BRANCH = 87

        class << self
          def start!(minimum_line: DEFAULT_MINIMUM_LINE, minimum_branch: DEFAULT_MINIMUM_BRANCH, filters: [])
            return unless ENV["COVERAGE"]

            require "simplecov"
            require "simplecov-lcov"

            configure_lcov_formatter
            configure_formatters
            start_simplecov(minimum_line: minimum_line, minimum_branch: minimum_branch, filters: filters)
            nil
          end

          def configure_lcov_formatter
            SimpleCov::Formatter::LcovFormatter.config do |config|
              config.report_with_single_file = true
              config.output_directory = "coverage/lcov"
              config.lcov_file_name = "lcov.info"
              config.single_report_path = "coverage/lcov/lcov.info"
            end
          end

          def configure_formatters
            SimpleCov.formatter = SimpleCov::Formatter::MultiFormatter.new(
              [
                SimpleCov::Formatter::HTMLFormatter,
                SimpleCov::Formatter::LcovFormatter
              ]
            )
          end

          def start_simplecov(minimum_line:, minimum_branch:, filters:)
            SimpleCov.start do
              enable_coverage :branch
              minimum_coverage line: minimum_line, branch: minimum_branch if minimum_line || minimum_branch
              track_files "lib/**/*.rb"
              add_filter "/test/"
              add_filter "/lib/julewire/core/testing/coverage.rb"
              add_filter %r{/lib/julewire/[^/]+/version\.rb\z}
              add_filter %r{/lib/julewire-[^/]+\.rb\z}
              filters.each { add_filter(it) }
            end
          end
        end
      end
    end
  end
end
