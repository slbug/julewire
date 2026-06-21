# frozen_string_literal: true

require "json"

module Julewire
  module Core
    class CLI
      class Doctor
        FLAGS = {
          "--color" => [:color, true],
          "--json" => %i[format json],
          "--no-color" => [:color, false],
          "--plain" => %i[theme plain],
          "--punk" => %i[theme punk],
          "--text" => %i[format text]
        }.freeze

        def initialize(argv:, stdout:)
          @argv = argv
          @stdout = stdout
        end

        def call
          options = doctor_options
          report = Julewire.doctor
          options.fetch(:format) == :json ? write_json(report) : write_text(report, options)
          0
        end

        private

        def doctor_options
          { color: color_output?, format: :json, theme: :plain }.tap do |options|
            until @argv.empty?
              value = @argv.shift
              if (assignment = FLAGS[value])
                apply_option(options, assignment)
              else
                raise ArgumentError, "unknown option #{value}"
              end
            end
          end
        end

        def apply_option(options, assignment)
          key = assignment.fetch(0)
          value = assignment.fetch(1)
          options[key] = value
          options[:format] = :text if key == :theme && value == :punk
        end

        def color_output?
          @stdout.respond_to?(:tty?) && @stdout.tty?
        end

        def write_json(report)
          @stdout.write(JSON.pretty_generate(report))
          @stdout.write("\n")
        end

        def write_text(report, options)
          theme = options.fetch(:theme)
          color = options.fetch(:color)
          lines = [
            title(theme),
            status_line(report, theme: theme, color: color),
            runtime_line(report.fetch(:runtime)),
            pipeline_line(report.fetch(:pipeline)),
            component_line("destinations", report.dig(:pipeline, :destinations) || {}),
            component_line("runtime_integrations", report.fetch(:integrations)),
            component_line("process_integrations", report.fetch(:process_integrations)),
            warning_lines(report.fetch(:warnings), theme: theme)
          ].flatten.compact
          @stdout.write("#{lines.join("\n")}\n")
        end

        def title(theme)
          theme == :punk ? "!! JULEWIRE DOCTOR !!" : "Julewire Doctor"
        end

        def status_line(report, theme:, color:)
          status = report.fetch(:status).to_s
          label = theme == :punk ? punk_label(status) : "status=#{status}"
          colorize(label, severity_for_status(status), color: color, theme: theme)
        end

        def runtime_line(runtime)
          parts = [
            "level=#{runtime.fetch(:level)}",
            "generation=#{runtime.fetch(:generation)}",
            "closed=#{runtime.fetch(:closed)}"
          ]
          "runtime #{parts.join(" ")}"
        end

        def pipeline_line(pipeline)
          "pipeline configured=#{pipeline.fetch(:configured)} status=#{pipeline.fetch(:status)}"
        end

        def component_line(name, components)
          return "#{name}=none" if components.empty?

          values = components.map { |key, value| "#{key}:#{value.fetch(:status)}" }
          "#{name}=#{values.join(",")}"
        end

        def warning_lines(warnings, theme:)
          return "warnings=none" if warnings.empty?

          header = theme == :punk ? "!! warnings=#{warnings.length}" : "warnings=#{warnings.length}"
          [header, *warnings.map { warning_line(it, theme: theme) }]
        end

        def warning_line(warning, theme:)
          prefix = theme == :punk ? "!!" : "-"
          "#{prefix} #{warning.fetch(:code)}: #{warning.fetch(:message)}"
        end

        def punk_label(status)
          glyph = Serialization::TextEncoder.punk_glyph(severity_for_status(status))
          "#{glyph} status=#{status.upcase} #{glyph}"
        end

        def colorize(value, severity, color:, theme:)
          return value unless color

          styles = severity_styles(theme)
          "\e[#{styles.fetch(severity.to_s, styles.fetch("unknown"))}m#{value}\e[0m"
        end

        def severity_for_status(status)
          status == "ok" ? "info" : "error"
        end

        def severity_styles(theme)
          return Serialization::TextEncoder::PUNK_SEVERITY_STYLES if theme == :punk

          Serialization::TextEncoder::SEVERITY_STYLES
        end
      end
    end
  end
end
