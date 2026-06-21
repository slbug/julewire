# frozen_string_literal: true

require "rails"
require "action_controller/railtie"
require "active_record/railtie"
require "julewire/rails"

module JulewireRailsDummy
  class Application < ::Rails::Application
    config.load_defaults 8.1

    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.enable_reloading = false
    config.hosts.clear
    config.secret_key_base = "julewire-rails-dummy-test-key"
    config.log_level = :debug

    config.julewire_rails.require_output = false
    config.julewire_rails.lifecycle_hooks = false
    config.julewire_rails.carry_request_headers = %w[traceparent x-cloud-trace-context]
    config.julewire_rails.request_capture.headers = true
    config.julewire_rails.request_capture.body = true
    config.julewire_rails.response_capture.headers = true
    config.julewire_rails.response_capture.body = true
    config.julewire_rails.response_capture.body_bytes = 64

    config.active_record.schema_format = :ruby

    config.after_initialize do
      Rails.event.debug_mode = true
    end
  end
end
