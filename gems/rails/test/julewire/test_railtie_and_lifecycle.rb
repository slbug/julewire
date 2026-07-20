# frozen_string_literal: true

require "test_helper"
require "timeout"

module Julewire
  class TestRailtieAndLifecycle < Minitest::Test
    cover "Julewire::Rails::Configuration#silence_log_subscribers?"
    cover "Julewire::Rails::Railtie.configure_exception_logging"
    cover "Julewire::Rails::Railtie.finish_initialization!"
    cover "Julewire::Rails::Railtie.initialize_exception_logging!"
    cover "Julewire::Rails::Railtie.initialize_logger!"
    cover "Julewire::Rails::Railtie.initialize_request_middleware!"
    cover "Julewire::Rails::Railtie.install_request_middleware"
    cover "Julewire::Rails::Railtie.log_rescued_responses_value"
    cover "Julewire::Rails::Railtie.validated_settings"
    cover Julewire::Rails::LifecycleHooks
    cover Julewire::Rails::LoggerOutputs
    cover Julewire::Rails::OutputRequirement
    AppConfig = Data.define(:middleware, :action_dispatch)
    App = Data.define(:config)

    class ActionDispatchConfig
      attr_accessor :log_rescued_responses

      def initialize(log_rescued_responses)
        @log_rescued_responses = log_rescued_responses
      end
    end

    def test_railtie_logger_initializer_skips_disabled_logger
      settings = Julewire::Rails::Configuration.new
      settings.logger = false
      config = ActiveSupport::OrderedOptions.new
      config.julewire_rails = settings

      assert_nil Julewire::Rails::Railtie.initialize_logger!(App.new(config))
      assert_nil config.logger
    end

    def test_railtie_logger_initializer_installs_configured_tagged_logger_and_output_detection
      output = configure_output
      settings = Julewire::Rails::Configuration.new
      settings.logger_name = "Application"
      settings.source = "application"
      config = ActiveSupport::OrderedOptions.new
      config.julewire_rails = settings
      config.log_level = :warn
      config.log_formatter = ::Logger::Formatter.new
      fake_active_support_logger = Class.new do
        def self.logger_outputs_to?(*) = false
      end
      shadow_active_support = Module.new
      shadow_active_support.const_set(:TaggedLogging, Class.new do
        def self.new(*) = raise "nested ActiveSupport must not be used"
      end)

      with_temporary_constant(::ActiveSupport, :Logger, fake_active_support_logger) do
        with_temporary_constant(Julewire::Rails, :ActiveSupport, shadow_active_support) do
          Julewire::Rails::Railtie.initialize_logger!(App.new(config))
        end

        installed_logger = config.logger

        assert_instance_of Julewire::Rails::Logger, installed_logger
        assert_equal ::Logger::WARN, installed_logger.level
        assert_equal "Application", installed_logger.progname
        assert_instance_of ::Logger::Formatter, installed_logger.formatter
        assert_includes installed_logger.singleton_class.ancestors, ::ActiveSupport::TaggedLogging
        assert_true fake_active_support_logger.logger_outputs_to?(installed_logger, $stdout)

        installed_logger.warn("initialized logger")
      end

      record = parse_records(output).fetch(0)

      assert_equal "Application", record.fetch("logger")
      assert_equal "application", record.fetch("source")
    end

    def test_railtie_request_middleware_initializer_skips_disabled_middleware
      settings = Julewire::Rails::Configuration.new
      settings.request_middleware = false
      middleware = Julewire::Rails::TestHelpers::FakeMiddlewareStack.new
      config = ActiveSupport::OrderedOptions.new
      config.julewire_rails = settings
      config.middleware = middleware

      assert_nil Julewire::Rails::Railtie.initialize_request_middleware!(App.new(config))
      assert_empty middleware.calls
    end

    def test_railtie_request_middleware_initializer_installs_configured_stack_entry
      settings = Julewire::Rails::Configuration.new
      middleware = Julewire::Rails::TestHelpers::FakeMiddlewareStack.new
      config = ActiveSupport::OrderedOptions.new
      config.julewire_rails = settings
      config.middleware = middleware
      config.log_tags = [:request_id]
      app = App.new(config)

      Julewire::Rails::Railtie.initialize_request_middleware!(app)

      expected = [:swap, ::Rails::Rack::Logger, Julewire::Rails::RequestMiddleware, settings, [:request_id]]

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
      failure = Julewire.health.dig(:process_integrations, :rails, :last_failure)

      assert_equal :request_middleware, failure.fetch(:component)
      assert_equal :install, failure.fetch(:action)
      assert_equal "RuntimeError", failure.fetch(:class)
    end

    def test_logger_outputs_patch_prevents_rails_server_stdout_broadcast
      logger = ActiveSupport::BroadcastLogger.new(Julewire::Rails::Logger.new(name: "Rails"))

      Julewire::Rails::LoggerOutputs.install!

      assert_true ActiveSupport::Logger.logger_outputs_to?(logger, $stdout, $stderr)
      assert_false ActiveSupport::Logger.logger_outputs_to?(logger, "log/development.log")
    end

    def test_logger_outputs_predicates_match_any_julewire_logger_and_console_source
      broadcast = Data.define(:broadcasts)
      julewire_logger = Julewire::Rails::Logger.new(name: "Rails")

      assert_true Julewire::Rails::LoggerOutputs.julewire_logger?(julewire_logger)
      assert_true Julewire::Rails::LoggerOutputs.julewire_logger?(broadcast.new([Object.new, julewire_logger]))
      assert_false Julewire::Rails::LoggerOutputs.julewire_logger?(Object.new)
      assert_false Julewire::Rails::LoggerOutputs.julewire_logger?(broadcast.new([Object.new]))

      assert_true Julewire::Rails::LoggerOutputs.console_sources?(["log/development.log", $stdout])
      assert_false Julewire::Rails::LoggerOutputs.console_sources?(["log/development.log"])
    end

    def test_logger_outputs_install_patches_current_active_support_logger
      logger = Julewire::Rails::Logger.new(name: "Rails")
      fake_logger = Class.new
      active_support = Module.new
      active_support.const_set(:Logger, fake_logger)
      shadow_active_support = Module.new
      shadow_active_support.const_set(:Logger, Class.new(BasicObject).new)

      with_temporary_constant(Object, :ActiveSupport, active_support) do
        with_temporary_constant(Julewire::Rails, :ActiveSupport, shadow_active_support) do
          Julewire::Rails::LoggerOutputs.install!
        end

        assert_true fake_logger.logger_outputs_to?(logger, $stdout)
      end
    end

    def test_logger_outputs_patch_delegates_for_unowned_cases
      fake_logger = Class.new do
        def self.logger_outputs_to?(*) = :from_super # rubocop:disable Naming/PredicateMethod
      end
      active_support = Module.new
      active_support.const_set(:Logger, fake_logger)
      julewire_logger = Julewire::Rails::Logger.new(name: "Rails")

      with_temporary_constant(Object, :ActiveSupport, active_support) do
        Julewire::Rails::LoggerOutputs.install!

        assert_equal :from_super, fake_logger.logger_outputs_to?(Object.new, $stdout)
        assert_equal :from_super, fake_logger.logger_outputs_to?(julewire_logger, "log/development.log")
        assert_true fake_logger.logger_outputs_to?(julewire_logger, $stdout)
      end
    end

    def test_log_subscriber_silencing_defaults_to_logger_replacement_mode
      settings = Julewire::Rails::Configuration.new

      assert_true settings.silence_log_subscribers?
      assert_equal :warn, settings.require_output
      refute_predicate settings, :rendered_exceptions?
      assert_equal :auto, settings.log_rescued_responses
      assert_equal :auto, settings.reported_exception_logs

      settings.logger = false

      assert_false settings.silence_log_subscribers?

      settings.silence_log_subscribers = true

      assert_true settings.silence_log_subscribers?

      settings.silence_log_subscribers = "yes"

      assert_true settings.silence_log_subscribers?

      settings.silence_log_subscribers = false

      assert_false settings.silence_log_subscribers?
    end

    def test_railtie_exception_logging_initializer_maps_auto_to_silenced_rescued_text
      settings = Julewire::Rails::Configuration.new
      action_dispatch = ActionDispatchConfig.new(true)
      config = ActiveSupport::OrderedOptions.new
      config.julewire_rails = settings
      config.action_dispatch = action_dispatch
      app = App.new(config)

      Julewire::Rails::Railtie.initialize_exception_logging!(app)

      assert_false action_dispatch.log_rescued_responses
    end

    def test_railtie_initialization_rejects_invalid_configuration_before_side_effects
      settings = Julewire::Rails::Configuration.new
      settings.request_exclude_prefixes << "relative"
      config = ActiveSupport::OrderedOptions.new
      config.julewire_rails = settings

      error = assert_raises(Julewire::Rails::Error) do
        Julewire::Rails::Railtie.initialize_exception_logging!(App.new(config))
      end

      assert_equal "request_exclude_prefixes must contain absolute path prefixes", error.message
    end

    def test_railtie_finish_enforces_output_requirement
      settings = Julewire::Rails::Configuration.new
      settings.require_output = :raise
      config = ActiveSupport::OrderedOptions.new
      config.julewire_rails = settings

      error = assert_raises(Julewire::Rails::Error) do
        Julewire::Rails::Railtie.finish_initialization!(App.new(config))
      end

      assert_match(/no configured destinations/, error.message)
    end

    def test_railtie_finish_installs_lifecycle_resets_subscribers_and_configures_silencing
      settings = Julewire::Rails::Configuration.new
      settings.require_output = false
      settings.error_reports = false
      settings.request_summary = false
      settings.structured_events = false
      settings.reported_exception_logs = false
      config = ActiveSupport::OrderedOptions.new
      config.julewire_rails = settings
      hooks = []
      previous_silencer_configuration =
        Julewire::Rails::DebugExceptionLogSilencer.instance_variable_get(:@configuration)
      allowed_logs = Julewire::Rails::Configuration.new
      allowed_logs.reported_exception_logs = true

      Julewire::Rails::Subscribers::RenderedException.install!(Julewire::Rails::Configuration.new)
      Julewire::Rails::DebugExceptionLogSilencer.install!(allowed_logs)

      assert_predicate Julewire::Rails::Subscribers::RenderedException, :installed?
      assert_false Julewire::Rails::DebugExceptionLogSilencer.suppress?

      with_overridden_singleton_method(Kernel, :at_exit, proc { |&hook| hooks << hook }) do
        Julewire::Rails::Railtie.finish_initialization!(App.new(config))
      end

      assert_equal 1, hooks.size
      refute_predicate Julewire::Rails::Subscribers::RenderedException, :installed?
      assert_true Julewire::Rails::DebugExceptionLogSilencer.suppress?
    ensure
      Julewire::Rails::Subscribers::RenderedException.reset!
      Julewire::Rails::DebugExceptionLogSilencer.install!(previous_silencer_configuration)
    end

    def test_railtie_exception_logging_preserves_auto_when_logger_is_disabled
      settings = Julewire::Rails::Configuration.new
      settings.logger = false

      action_dispatch = configured_exception_logging(settings)

      assert_true action_dispatch.log_rescued_responses
    end

    def test_railtie_exception_logging_preserves_auto_when_request_summary_is_disabled
      settings = Julewire::Rails::Configuration.new
      settings.request_summary = false

      action_dispatch = configured_exception_logging(settings)

      assert_true action_dispatch.log_rescued_responses
    end

    def test_railtie_exception_logging_allows_explicit_rescued_text_choice
      settings = Julewire::Rails::Configuration.new
      settings.log_rescued_responses = true
      action_dispatch = ActionDispatchConfig.new(false)
      app = App.new(AppConfig.new(middleware: nil, action_dispatch: action_dispatch))

      Julewire::Rails::Railtie.configure_exception_logging(app, settings)

      assert_true action_dispatch.log_rescued_responses

      settings.log_rescued_responses = false

      Julewire::Rails::Railtie.configure_exception_logging(app, settings)

      assert_false action_dispatch.log_rescued_responses
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

    def test_output_requirement_uses_default_warning_target
      settings = Julewire::Rails::Configuration.new
      messages = []

      with_overridden_singleton_method(::Warning, :warn, proc { |message| messages << message }) do
        Julewire::Rails::OutputRequirement.check!(settings, health: { pipeline: { configured: false } })
      end

      assert_equal 1, messages.size
      assert_match(/no configured destinations/, messages.fetch(0))
    end

    def test_output_requirement_mode_matrix
      warning_modes = [true, :warn, "warn"]
      disabled_modes = [false, nil]
      raise_modes = [:raise, "raise"]

      warning_modes.each do |mode|
        settings = Julewire::Rails::Configuration.new
        settings.require_output = mode
        messages = []
        warning = Object.new
        warning.define_singleton_method(:warn) { |message| messages << message }

        Julewire::Rails::OutputRequirement.check!(settings, health: {}, warning: warning)

        assert_equal 1, messages.length, "mode #{mode.inspect}"
      end

      disabled_modes.each do |mode|
        settings = Julewire::Rails::Configuration.new
        settings.require_output = mode
        warning = Object.new
        warning.define_singleton_method(:warn) { |_message| raise "disabled mode should not warn" }

        Julewire::Rails::OutputRequirement.check!(settings, health: {}, warning: warning)
      end

      raise_modes.each do |mode|
        settings = Julewire::Rails::Configuration.new
        settings.require_output = mode

        error = assert_raises(Julewire::Rails::Error, "mode #{mode.inspect}") do
          Julewire::Rails::OutputRequirement.check!(settings, health: {})
        end

        assert_match(/no configured destinations/, error.message)
      end
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
      [:bad, ""].each do |mode|
        settings.require_output = mode

        error = assert_raises(Julewire::Rails::Error) { Julewire::Rails::OutputRequirement.check!(settings) }

        assert_equal "config.julewire_rails.require_output must be false, :warn, or :raise", error.message
      end
    end

    def test_output_requirement_ignores_configured_destination
      settings = Julewire::Rails::Configuration.new
      settings.require_output = :raise
      configure_output

      Julewire::Rails::OutputRequirement.check!(settings)

      assert_true Julewire.health.dig(:pipeline, :configured)
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

    def test_lifecycle_hooks_use_kernel_as_default_at_exit_registrar
      settings = Julewire::Rails::Configuration.new
      hooks = []

      with_overridden_singleton_method(Kernel, :at_exit, proc { |&block| hooks << block }) do
        Julewire::Rails::LifecycleHooks.install!(settings, fork_tracker: Object.new)
      end

      assert_equal 1, hooks.size
    end

    def test_lifecycle_hooks_do_not_install_duplicate_process_hooks
      settings = Julewire::Rails::Configuration.new
      registrar = Julewire::Rails::TestHelpers::FakeAtExit.new
      fork_tracker = Julewire::Rails::TestHelpers::FakeForkTracker.new

      Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar, fork_tracker: fork_tracker)
      Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar, fork_tracker: fork_tracker)

      assert_equal 1, registrar.hooks.size
      assert_equal 1, fork_tracker.hooks.size
    end

    def test_lifecycle_hooks_serializes_concurrent_install
      settings = Julewire::Rails::Configuration.new
      entered = Queue.new
      ready = Queue.new
      release = Queue.new
      start = Queue.new
      hooks = []
      registrar = Object.new
      registrar.define_singleton_method(:at_exit) do |&block|
        entered << true
        release.pop
        hooks << block
      end

      threads = Array.new(8) do
        Thread.new do
          Thread.current.report_on_exception = false
          ready << true
          start.pop
          Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar, fork_tracker: Object.new)
        end
      end
      Timeout.timeout(1) { 8.times { ready.pop } }
      8.times { start << true }
      Timeout.timeout(1) { entered.pop }
      8.times { release << true }
      threads.each { |thread| Timeout.timeout(1) { thread.value } }

      assert_equal 1, hooks.size
    ensure
      8.times do
        start&.push(true)
        release&.push(true)
      end
      threads&.each do |thread|
        next if thread.join(0.1)

        thread.kill
        thread.join(0.1)
      end
    end

    def test_lifecycle_hooks_default_fork_tracker_uses_top_level_active_support
      settings = Julewire::Rails::Configuration.new
      registrar = Julewire::Rails::TestHelpers::FakeAtExit.new
      fork_tracker = Julewire::Rails::TestHelpers::FakeForkTracker.new
      top_level_active_support = Module.new
      nested_active_support = Module.new
      nested_fork_tracker = Object.new
      nested_fork_tracker.define_singleton_method(:after_fork) { raise "nested ActiveSupport must not be used" }
      top_level_active_support.const_set(:ForkTracker, fork_tracker)
      nested_active_support.const_set(:ForkTracker, nested_fork_tracker)

      with_temporary_constant(Object, :ActiveSupport, top_level_active_support) do
        with_temporary_constant(Julewire::Rails::LifecycleHooks, :ActiveSupport, nested_active_support) do
          Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar)
        end
      end

      assert_equal 1, fork_tracker.hooks.size
    end

    def test_lifecycle_hooks_skip_absent_default_fork_tracker
      settings = Julewire::Rails::Configuration.new
      registrar = Julewire::Rails::TestHelpers::FakeAtExit.new
      top_level_active_support = Module.new

      with_temporary_constant(Object, :ActiveSupport, top_level_active_support) do
        Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar)
      end

      assert_equal 1, registrar.hooks.size
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
      fork_tracker.define_singleton_method(:after_fork) { raise "fork tracker failed" }

      Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar, fork_tracker: fork_tracker)

      health = Julewire.health.fetch(:process_integrations).fetch(:rails)

      assert_equal 1, registrar.hooks.size
      assert_equal :degraded, health.fetch(:status)
      assert_equal :install_after_fork, health.dig(:last_failure, :action)
      assert_equal :lifecycle_hooks, health.dig(:last_failure, :component)
      assert_equal "RuntimeError", health.dig(:last_failure, :class)
    end

    def test_lifecycle_hooks_register_core_after_fork_cleanup
      settings = Julewire::Rails::Configuration.new
      registrar = Julewire::Rails::TestHelpers::FakeAtExit.new
      calls = []
      registrations = []

      with_overridden_singleton_method(
        Julewire::Core::Integration::Lifecycle,
        :register_after_fork,
        proc { |integration, component:, &block| registrations << [integration, component, block] }
      ) do
        with_overridden_singleton_method(
          Julewire::Rails::RequestSummaryTimeoutScheduler,
          :after_fork!,
          proc { calls << :request_summary_timeout_scheduler }
        ) do
          with_overridden_singleton_method(
            Julewire::Rails::RequestErrorOwnership,
            :clear,
            proc { calls << :request_error_ownership }
          ) do
            Julewire::Rails::LifecycleHooks.install!(settings, registrar: registrar, fork_tracker: Object.new)
            registrations.fetch(0).fetch(2).call
          end
        end
      end

      assert_equal([%i[rails lifecycle_hooks]], registrations.map do |integration, component, _block|
        [integration, component]
      end)
      assert_equal %i[request_summary_timeout_scheduler request_error_ownership], calls
    end

    def with_optional_require_stub(stub, &)
      with_overridden_singleton_method(Julewire::Core::Integration::Lifecycle, :require_optional, stub, &)
    end

    def configured_exception_logging(settings)
      action_dispatch = ActionDispatchConfig.new(true)
      app = App.new(AppConfig.new(middleware: nil, action_dispatch: action_dispatch))

      Julewire::Rails::Railtie.configure_exception_logging(app, settings)

      action_dispatch
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
  end

  class TestRailsInternalSubscriberPaths < Minitest::Test
    cover Julewire::Rails::LifecycleHooks
    cover Julewire::Rails::LoggerOutputs
    cover Julewire::Rails::OutputRequirement
    def test_log_subscriber_paths_resolve_against_current_rails
      Julewire::Rails::LogSubscriberSilencer::LOG_SUBSCRIBER_FILES.each do |path|
        refute_nil Julewire::Core::Integration::Lifecycle.require_optional(path), "#{path} should resolve"
      end
    end
  end
end
