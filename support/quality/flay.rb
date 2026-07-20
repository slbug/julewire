# frozen_string_literal: true

module Julewire
  module Quality
    module Flay
      SCORE_PATTERN = /^Total score \(lower is better\) = (\d+)$/

      class << self
        def assert_baselines!(scores:, baselines:)
          regressions = scores.filter_map do |dir, score|
            baseline = baselines.fetch(dir)
            "#{dir}: #{score} (baseline #{baseline})" if score > baseline
          end
          return if regressions.empty?

          raise "production Flay score regressions:\n#{regressions.join("\n")}" \
                "\nRun `rake all:flay_production_report` to inspect the production report."
        end
      end
    end
  end
end
