# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      module TestReports
        module_function

        def start!(enabled: ENV.fetch("JULEWIRE_JUNIT", nil),
                   reports_dir: ENV.fetch("JULEWIRE_JUNIT_DIR", "test/reports"))
          return unless enabled

          require "fileutils"
          require "minitest/reporters"

          FileUtils.mkdir_p(reports_dir)
          junit = Minitest::Reporters::JUnitReporter.new(
            reports_dir,
            true,
            base_path: Dir.pwd,
            include_timestamp: true,
            single_file: true
          )

          Minitest::Reporters.use!(
            [Minitest::Reporters::DefaultReporter.new, junit],
            ENV,
            Minitest.backtrace_filter
          )
        end
      end
    end
  end
end
