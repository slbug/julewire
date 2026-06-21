# frozen_string_literal: true

module Julewire
  module Core
    module Testing
      module TestReports
        module CodecovJUnitReportMethods
          def report
            return super unless @single_file

            puts "Writing XML reports to #{reports_path}"
            File.write(filename_for("minitest"), testsuites_xml)
          end

          private

          def testsuites_xml
            suites = tests.group_by { test_class(it) }
            result = analyze_suite(tests)
            xml = Builder::XmlMarkup.new(indent: 2)
            xml.instruct!
            xml.testsuites(testsuite_result_attributes(result)) do
              suites.each do |suite, suite_tests|
                parse_xml_for(xml, suite, suite_tests)
              end
            end

            xml.target!
          end

          def testsuite_result_attributes(result)
            {
              name: "minitest",
              skipped: result[:skip_count],
              failures: result[:fail_count],
              errors: result[:error_count],
              tests: result[:test_count],
              assertions: result[:assertion_count],
              time: result[:time]
            }
          end
        end
        private_constant :CodecovJUnitReportMethods

        module_function

        def start!(enabled: ENV.fetch("JULEWIRE_JUNIT", nil),
                   reports_dir: ENV.fetch("JULEWIRE_JUNIT_DIR", "test/reports"))
          return unless enabled

          require "fileutils"
          require "minitest/reporters"

          FileUtils.mkdir_p(reports_dir)
          junit = junit_reporter_class.new(
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

        def junit_reporter_class
          @junit_reporter_class ||= Class.new(Minitest::Reporters::JUnitReporter) do
            include CodecovJUnitReportMethods
          end
        end
      end
    end
  end
end
