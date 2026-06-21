# frozen_string_literal: true

Julewire.configure do |config|
  config.destinations.use(:default, output: $stdout) if config.destinations.empty?

  config.processors.prepend(
    :rails_parameter_filter,
    Rails.application.config.filter_parameters
  )
end

Julewire::Rails.configure do |config|
  config.request_summary = true
  config.structured_events = true
  config.error_reports = true
end
