# frozen_string_literal: true

require "test_helper"

module Julewire
  class TestRailtieAndLifecycle < Minitest::Test
    AppConfig = Data.define(:middleware, :action_dispatch)
    App = Data.define(:config)

    class ActionDispatchConfig
      attr_accessor :log_rescued_responses

      def initialize(log_rescued_responses)
        @log_rescued_responses = log_rescued_responses
      end
    end

    def test_railtie_request_middleware_installer_is_callable_from_initializer_context
      settings = Julewire::Rails::Configuration.new
      middleware = Julewire::Rails::TestHelpers::FakeMiddlewareStack.new
      app = App.new(AppConfig.new(middleware: middleware, action_dispatch: nil))

      Julewire::Rails::Railtie.install_request_middleware(app, settings)

      expected = [:swap, ::Rails::Rack::Logger, Julewire::Rails::RequestMiddleware, settings, nil]

      assert_equal expected, middleware.calls.fetch(0)
    end

    def test_railtie_request_middleware_installer_can_insert_after
      settings = Julewire::Rails::Configuration.new
      settings.replace_rack_logger = false
      middleware = Julewire::Rails::TestHelpers::FakeMiddlewareStack.new
      app = App.new(AppConfig.new(middleware: middleware, action_dispatch: nil))

      Julewire::Rails::Railtie.install_request_middleware(app, settings, [:request_id])

      assert_equal :insert_after, middleware.calls.fetch(0).fetch(0)
      assert_equal [:request_id], middleware.calls.fetch(0).fetch(4)
    end

    def test_railtie_request_middleware_installer_reports_failures
      failing_middleware = Class.new(Julewire::Rails::TestHelpers::FakeMiddlewareStack) do
        def swap(*) = raise "swap failed"
      end.new
      app = App.new(AppConfig.new(middleware: failing_middleware, action_dispatch: nil))

      error = assert_raises(RuntimeError) do
        Julewire::Rails::Railtie.install_request_middleware(app, Julewire::Rails::Configuration.new)
      end

      assert_equal "swap failed", error.message
      assert_equal :degraded, Julewire.health.dig(:process_integrations, :rails, :status)
      assert_equal :request_middleware, Julewire.health.dig(:process_integrations, :rails, :last_failure, :component)
    end

    def test_logger_outputs_patch_prevents_rails_server_stdout_broadcast
      logger = ActiveSupport::BroadcastLogger.new(Julewire::Rails::Logger.new(name: "Rails"))

      Julewire::Rails::LoggerOutputs.install!

      assert ActiveSupport::Logger.logger_outputs_to?(logger, $stdout, $stderr)
      refute ActiveSupport::Logger.logger_outputs_to?(logger, "log/development.log")
    end

    def test_log_subscriber_silencing_defaults_to_logger_replacement_mode
      settings = Julewire::Rails::Configuration.new

      assert_predicate settings, :silence_log_subscribers?
      assert_equal :warn, settings.require_output
      refute_predicate settings, :rendered_exceptions?
      assert_equal :auto, settings.log_rescued_responses
      assert_equal :auto, settings.reported_exception_logs

      settings.logger = false

      refute_predicate settings, :silence_log_subscribers?

      settings.silence_log_subscribers = true

      assert_predicate settings, :silence_log_subscribers?

      settings.silence_log_subscribers = false

      refute_predicate settings, :silence_log_subscribers?
    end

    def test_railtie_exception_logging_maps_auto_to_silenced_rescued_text
      settings = Julewire::Rails::Configuration.new
      action_dispatch = ActionDispatchConfig.new(true)
      app = App.new(AppConfig.new(middleware: nil, action_dispatch: action_dispatch))

      Julewire::Rails::Railtie.configure_exception_logging(app, settings)

      refute action_dispatch.log_rescued_responses
    end

    def test_railtie_exception_logging_preserves_auto_when_logger_is_disabled
      settings = Julewire::Rails::Configuration.new
      settings.logger = false
      action_dispatch = ActionDispatchConfig.new(true)
      app = App.new(AppConfig.new(middleware: nil, action_dispatch: action_dispatch))

      Julewire::Rails::Railtie.configure_exception_logging(app, settings)

      assert action_dispatch.log_rescued_responses
    end

    def test_railtie_exception_logging_allows_explicit_rescued_text_choice
      settings = Julewire::Rails::Configuration.new
      settings.log_rescued_responses = true
      action_dispatch = ActionDispatchConfig.new(false)
      app = App.new(AppConfig.new(middleware: nil, action_dispatch: action_dispatch))

      Julewire::Rails::Railtie.configure_exception_logging(app, settings)

      assert action_dispatch.log_rescued_responses
    end

    def test_log_subscriber_silencer_tolerates_missing_optional_subscribers
      stub = proc { |*| }

      assert_silent { with_optional_require_stub(stub) { Julewire::Rails::LogSubscriberSilencer.silence! } }
    end

    def test_output_requirement_warns_when_rails_logger_has_no_destination
      settings = Julewire::Rails::Configuration.new
      messages = []
      warning = Object.new
      warning.define_singleton_method(:warn) { messages << it }

      Julewire::Rails::OutputRequirement.check!(settings, warning: warning)

      assert_equal 1, messages.size
      assert_match(/no configured destinations/, messages.fetch(0))
    end

    def test_output_requirement_can_fail_fast
      settings = Julewire::Rails::Configuration.new
      settings.require_output = :raise

      error = assert_raises(Julewire::Rails::Error) do
        Julewire::Rails::OutputRequirement.check!(settings)
      end

      assert_match(/no configured destinations/, error.message)
    end

    def test_output_requirement_can_be_disabled
      settings = Julewire::Rails::Configuration.new
      settings.require_output = false
      messages = []
      warning = Object.new
      warning.define_singleton_method(:warn) { messages << it }

      Julewire::Rails::OutputRequirement.check!(settings, warning: warning)

      assert_empty messages
    end

    def test_output_requirement_ignores_when_logger_disabled_and_rejects_bad_mode
      settings = Julewire::Rails::Configuration.new
      settings.logger = false
      settings.require_output = :raise

      Julewire::Rails::OutputRequirement.check!(settings)

      settings.logger = true
      settings.require_output = :bad

      assert_raises(Julewire::Rails::Error) { Julewire::Rails::OutputRequirement.check!(settings) }
    end

    def test_output_requirement_ignores_configured_destination
      settings = Julewire::Rails::Configuration.new
      settings.require_output = :raise
      configure_output

      Julewire::Rails::OutputRequirement.check!(settings)

      assert Julewire.health.dig(:pipeline, :configured)
    end

    def test_rails_configure_yields_application_configuration
      configuration = Julewire::Rails::Configuration.new
      with_rails_application_config(configuration) do
        Julewire::Rails.configure { it.response_capture.body = true }

        assert_predicate configuration.response_capture, :body?
      end
    end

    def test_rails_configure_requires_block
      error = assert_raises(ArgumentError) { Julewire::Rails.configure }

      assert_equal "Julewire::Rails.configure requires a block", error.message
    end

    def test_rails_config_requires_application
      rails_singleton = class << ::Rails; self; end
      original_application = rails_singleton.instance_method(:application)
      verbose = $VERBOSE
      $VERBOSE = nil
      rails_singleton.define_method(:application) { nil }

      error = assert_raises(Julewire::Rails::Error) { Julewire::Rails.config }

      assert_equal "Rails.application is not available", error.message
    ensure
      rails_singleton&.define_method(:application, original_application)
      $VERBOSE = verbose
    end

    def test_lifecycle_hooks_register_at_exit_drain
      settings = Julewire::Rails::Configuration.new
      settings.shutdown_timeout = 0.25
      registrar = Julewire::Rails::TestHelpers::FakeAtExit.new
      fork_tracker = Julewire::Rails::TestHelpers::FakeForkTracker.new

      Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar, fork_tracker: fork_tracker)

      assert_equal 1, registrar.hooks.size
      assert_equal 1, fork_tracker.hooks.size
    end

    def test_lifecycle_hooks_skip_missing_fork_tracker
      settings = Julewire::Rails::Configuration.new
      registrar = Julewire::Rails::TestHelpers::FakeAtExit.new

      Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar, fork_tracker: Object.new)

      assert_equal 1, registrar.hooks.size
      assert_empty Julewire.health.fetch(:process_integrations)
    end

    def test_lifecycle_hooks_record_fork_tracker_install_failures
      settings = Julewire::Rails::Configuration.new
      registrar = Julewire::Rails::TestHelpers::FakeAtExit.new
      fork_tracker = Object.new
      fork_tracker.define_singleton_method(:after_fork) { |_block| raise "fork tracker failed" }

      Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar, fork_tracker: fork_tracker)

      health = Julewire.health.fetch(:process_integrations).fetch(:rails)

      assert_equal 1, registrar.hooks.size
      assert_equal :degraded, health.fetch(:status)
      assert_equal :install_after_fork, health.dig(:last_failure, :action)
    end

    def with_optional_require_stub(stub, &)
      with_overridden_singleton_method(Julewire::Core::Integration::Lifecycle, :require_optional, stub, &)
    end

    def test_lifecycle_hooks_can_be_disabled
      settings = Julewire::Rails::Configuration.new
      settings.lifecycle_hooks = false
      registrar = Julewire::Rails::TestHelpers::FakeAtExit.new
      fork_tracker = Julewire::Rails::TestHelpers::FakeForkTracker.new

      Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar, fork_tracker: fork_tracker)

      assert_empty registrar.hooks
      assert_empty fork_tracker.hooks
    end

    def test_lifecycle_hook_flushes_and_closes_julewire
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      registrar = Julewire::Rails::TestHelpers::FakeAtExit.new

      Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar)
      Julewire.emit(message: "before shutdown")
      registrar.hooks.fetch(0).call

      assert_match(/before shutdown/, output.string)
      assert_equal :closed, Julewire.health.fetch(:status)
    end

    def test_lifecycle_fork_hook_runs_julewire_after_fork
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      registrar = Julewire::Rails::TestHelpers::FakeAtExit.new
      fork_tracker = Julewire::Rails::TestHelpers::FakeForkTracker.new

      Julewire.emit(message: "before fork")

      assert_operator Julewire.health.dig(:pipeline, :counts, :entered), :>, 0

      Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar, fork_tracker: fork_tracker)
      fork_tracker.hooks.fetch(0).call

      assert_equal 0, Julewire.health.dig(:pipeline, :counts, :entered)
      assert_match(/before fork/, output.string)
    end

    def with_rails_application_config(configuration)
      rails_singleton = class << ::Rails; self; end
      original_application = rails_singleton.instance_method(:application)
      application = App.new(Data.define(:julewire_rails).new(configuration))
      verbose = $VERBOSE
      $VERBOSE = nil
      rails_singleton.define_method(:application) { application }
      yield
    ensure
      rails_singleton&.define_method(:application, original_application)
      $VERBOSE = verbose
    end
  end

  class TestRailsInternalSubscriberPaths < Minitest::Test
    def test_log_subscriber_paths_resolve_against_current_rails
      Julewire::Rails::LogSubscriberSilencer::LOG_SUBSCRIBER_FILES.each do |path|
        refute_nil Julewire::Core::Integration::Lifecycle.require_optional(path), "#{path} should resolve"
      end
    end
  end
end
