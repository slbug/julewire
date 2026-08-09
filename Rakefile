# frozen_string_literal: true

require "bundler"
require "rbconfig"
require "fileutils"
require "open3"
require_relative "support/mutant/targets"
require_relative "support/quality/api_tags"
require_relative "support/quality/boundaries"
require_relative "support/quality/flay"
require_relative "support/quality/release_metadata"

GEM_DIRS = %w[
  gems/core
  gems/rack
  gems/rails
  gems/rails_support
  gems/gcp
  gems/redaction
  gems/semantic_logger
  gems/ractor
  gems/active_job
  gems/karafka
].freeze

QUALITY_TASKS = %w[rubocop].freeze
FLAY_PRODUCTION_BASELINES = {
  "gems/active_job" => 0,
  "gems/core" => 0,
  "gems/gcp" => 0,
  "gems/karafka" => 0,
  "gems/rack" => 0,
  "gems/ractor" => 0,
  "gems/rails" => 0,
  "gems/rails_support" => 0,
  "gems/redaction" => 0,
  "gems/semantic_logger" => 0
}.freeze
API_TAG_VALUES = %w[
  public
  extension
  integration_spi
  bridge_spi
  internal
].freeze
API_TAG_REQUIREMENTS = {
  "gems/core/lib/julewire/core/destinations/tail_sampling.rb" => { "TailSampling" => "extension" },
  "gems/core/lib/julewire/core/destinations/write_step.rb" => { "WriteStep" => "integration_spi" },
  "gems/core/lib/julewire/core/execution/view.rb" => { "View" => "public" },
  "gems/core/lib/julewire/core/fields/attribute_keys.rb" => { "AttributeKeys" => "integration_spi" },
  "gems/core/lib/julewire/core/fields/bags.rb" => { "Bags" => "extension" },
  "gems/core/lib/julewire/core/fields/field_set.rb" => { "FieldSet" => "integration_spi" },
  "gems/core/lib/julewire/core/integration/configurable.rb" => { "Configurable" => "integration_spi" },
  "gems/core/lib/julewire/core/integration/destination_health.rb" => { "DestinationHealth" => "integration_spi" },
  "gems/core/lib/julewire/core/integration/event_subscriber.rb" => { "EventSubscriber" => "integration_spi" },
  "gems/core/lib/julewire/core/integration/facade.rb" => { "Facade" => "integration_spi" },
  "gems/core/lib/julewire/core/integration/health.rb" => { "Health" => "integration_spi" },
  "gems/core/lib/julewire/core/integration/ivar_state.rb" => { "IvarState" => "integration_spi" },
  "gems/core/lib/julewire/core/integration/lifecycle.rb" => { "Lifecycle" => "integration_spi" },
  "gems/core/lib/julewire/core/integration/scoped.rb" => { "Scoped" => "integration_spi" },
  "gems/core/lib/julewire/core/integration/settings.rb" => { "Settings" => "integration_spi" },
  "gems/core/lib/julewire/core/integration/subscriber_install.rb" => { "SubscriberInstall" => "integration_spi" },
  "gems/core/lib/julewire/core/integration/subscription.rb" => { "Subscription" => "integration_spi" },
  "gems/core/lib/julewire/core/integration/values.rb" => {
    "Read" => "integration_spi",
    "Shape" => "integration_spi",
    "Values" => "integration_spi"
  },
  "gems/core/lib/julewire/core/processing/match.rb" => { "Match" => "extension" },
  "gems/core/lib/julewire/core/processing/sampling.rb" => { "Sampling" => "extension" },
  "gems/core/lib/julewire/core/propagation.rb" => { "Propagation" => "public" },
  "gems/core/lib/julewire/core/propagation/carrier.rb" => {
    "Carrier" => "public",
    "Extracted" => "integration_spi",
    "ExtractionError" => "integration_spi",
    "extract_result" => "integration_spi"
  },
  "gems/core/lib/julewire/core/records/build_input.rb" => { "BuildInput" => "bridge_spi" },
  "gems/core/lib/julewire/core/records/console_formatter.rb" => { "ConsoleFormatter" => "extension" },
  "gems/core/lib/julewire/core/records/draft.rb" => { "Draft" => "extension" },
  "gems/core/lib/julewire/core/records/formatter.rb" => { "Formatter" => "extension" },
  "gems/core/lib/julewire/core/records/record.rb" => { "Record" => "extension" },
  "gems/core/lib/julewire/core/serialization/bounded_transform.rb" => { "BoundedTransform" => "integration_spi" },
  "gems/core/lib/julewire/core/serialization/json_encoder.rb" => { "JsonEncoder" => "extension" },
  "gems/core/lib/julewire/core/serialization/text_encoder.rb" => { "TextEncoder" => "extension" },
  "gems/core/lib/julewire/core/testing.rb" => {
    "CaptureDestination" => "extension",
    "NullOutput" => "extension",
    "Testing" => "extension"
  },
  "gems/core/lib/julewire/core/unsafe_fork_error.rb" => { "UnsafeForkError" => "integration_spi" },
  "gems/core/lib/julewire/core/validation.rb" => { "Validation" => "integration_spi" }
}.freeze
INTEGRATION_GEM_DIRS = (GEM_DIRS - ["gems/core"]).freeze
INTEGRATION_NAMESPACES = {
  "gems/active_job" => "Julewire::ActiveJob",
  "gems/gcp" => "Julewire::GCP",
  "gems/karafka" => "Julewire::Karafka",
  "gems/rack" => "Julewire::Rack",
  "gems/ractor" => "Julewire::Ractor",
  "gems/rails" => "Julewire::Rails",
  "gems/rails_support" => "Julewire::RailsSupport",
  "gems/redaction" => "Julewire::Redaction",
  "gems/semantic_logger" => "Julewire::SemanticLogger"
}.freeze
MUTANT_NAMESPACES = INTEGRATION_NAMESPACES.merge("gems/core" => "Julewire::Core").freeze
MUTANT_ADDITIONAL_SUBJECTS = {
  "gems/core" => %w[Julewire::Mutant::Targets* Julewire::Quality*]
}.freeze
MUTANT_ALLOWED_CLASS_BODY_DEFINE_METHOD_COUNTS = {
  "gems/core/lib/julewire/core/records/draft.rb" => 1,
  "gems/core/lib/julewire/core/records/record.rb" => 1
}.freeze
MUTANT_REQUIRED_RUNTIME_SUBJECTS = {
  "gems/active_job" => ["Julewire::ActiveJob::Railtie.install_active_job!"],
  "gems/core" => [
    "Julewire::Mutant::Targets.update!",
    "Julewire::Mutant::Targets.assert_visible_method_shapes!",
    "Julewire::Core::Diagnostics::CallbackNotifier::Failure#to_h",
    "Julewire::Core::RuntimeState.default",
    "Julewire::Core::RuntimeState#closed",
    "Julewire::Core::RuntimeState#next_generation",
    "Julewire::Mutant::Targets::Discovery#call",
    "Julewire::Quality::ApiTags.assert!",
    "Julewire::Quality::Boundaries.assert_core_neutrality",
    "Julewire::Quality::Boundaries.assert_safe_method_names",
    "Julewire::Quality::Flay.assert_baselines!",
    "Julewire::Quality::ReleaseMetadata.assert!",
    "Julewire::Quality::RubySource.parse_file"
  ],
  "gems/rails" => [
    "Julewire::Generators::InstallGenerator#copy_initializer",
    "Julewire::Rails::DebugExceptionLogSilencer::Patch#log_error",
    "Julewire::Rails::Railtie.finish_initialization!",
    "Julewire::Rails::Railtie.initialize_exception_logging!",
    "Julewire::Rails::Railtie.initialize_logger!",
    "Julewire::Rails::Railtie.initialize_request_middleware!",
    "Julewire::Rails::Railtie.validated_settings"
  ]
}.freeze
OBJECT_METHOD_NAME_ALLOWLIST = %i[
  ==
  eql?
  freeze
  hash
  initialize
  initialize_copy
  inspect
  method_missing
  respond_to_missing?
  to_s
  warn
].freeze
INTEGRATION_ALLOWED_REFERENCES = {
  "gems/active_job" => %w[
    Julewire::RailsSupport
  ],
  "gems/rails" => %w[
    Julewire::Rack
    Julewire::RailsSupport
  ]
}.freeze
CORE_ALLOWED_TOP_LEVEL_CONSTANTS = %w[
  ARGV
  ArgumentError
  Array
  BigDecimal
  Class
  ConditionVariable
  Concurrent
  Data
  Date
  DateTime
  Dir
  ENV
  Encoding
  EncodingError
  Enumerable
  Errno
  Exception
  Fiber
  File
  FileUtils
  Float
  FrozenError
  Hash
  IO
  Integer
  Interrupt
  JSON
  Kernel
  LoadError
  Module
  Mutex
  NoMethodError
  Numeric
  Object
  ObjectSpace
  Proc
  Process
  Queue
  Ractor
  Random
  Range
  Regexp
  RuntimeError
  SecureRandom
  Set
  StandardError
  String
  Symbol
  SystemStackError
  Thread
  ThreadError
  Time
  Timeout
  TypeError
  Warning
  Zeitwerk
].freeze
CORE_ALLOWED_TOP_LEVEL_CONSTANTS_BY_PATH = {}.freeze
CORE_PUBLIC_ALIAS_PREFIXES = %w[
  Julewire::ConsoleFormatter
  Julewire::Error
  Julewire::JsonEncoder
  Julewire::Match
  Julewire::Record
  Julewire::RecordDraft
  Julewire::RecordFormatter
  Julewire::Sampling
  Julewire::Serializer
  Julewire::Tail
  Julewire::TailSampling
  Julewire::Testing
  Julewire::TextEncoder
  Julewire::UnsafeForkError
].freeze
CORE_SPI_ALLOWED_PREFIXES = %w[
  Core::CLI::LogFormats
  Core::DEFAULT_MAX_RECORD_BYTES
  Core::Destinations
  Core::Destinations::WriteStep
  Core::Diagnostics::CallbackNotifier
  Core::Diagnostics::FailureSnapshot
  Core::Error
  Core::Fields::AttributeKeys
  Core::Fields::Bags
  Core::Fields::FieldSet
  Core::Integration
  Core::Integration::DestinationHealth
  Core::Processing
  Core::Propagation
  Core::Records::DisplayMessage
  Core::Records::Metadata
  Core::Records::Severity
  Core::RuntimeLocator
  Core::Scheduling
  Core::Serialization::BoundedTransform
  Core::Serialization::EncodingSanitizer
  Core::UNSET
  Core::UnsafeForkError
  Core::Validation
].freeze
CORE_BRIDGE_ALLOWED_PREFIXES = %w[
  Core::ContextStore
  Core::Execution::Boundary
  Core::Execution::ScopeSnapshot
  Core::Execution::View
  Core::Records::BuildInput
  Core::Records::LazyEmitInput
  Core::Serialization::Serializer
].freeze
CUSTOM_GEMFILES = {
  "gems/rails" => %w[
    gemfiles/rails_8_1.gemfile
    gemfiles/rails_head.gemfile
  ],
  "gems/semantic_logger" => %w[
    gemfiles/semantic_logger_4.gemfile
    gemfiles/semantic_logger_5.gemfile
  ]
}.freeze
BUNDLE_LOCK_PLATFORMS = %w[
  ruby
  aarch64-linux
  aarch64-linux-musl
  arm64-darwin
  x86_64-darwin
  x86_64-linux
  x86_64-linux-musl
].freeze
BUNDLE_UPDATE_STEPS = [
  %w[update --all],
  %w[update --bundler],
  ["lock", "--add-platform", *BUNDLE_LOCK_PLATFORMS],
  %w[lock --normalize-platforms],
  %w[lock --add-checksums]
].freeze
MUTANT_CHANGE_BASE = "HEAD~1"
MUTANT_COMMAND_ENV = { "RUBY_YJIT_ENABLE" => "0" }.freeze

def run_in_gem(dir, *command, env: {}, raise_on_failure: true)
  puts "\n==> #{dir}: #{command.join(" ")}"
  run = proc { system(env, *command, chdir: dir) }
  succeeded = if defined?(Bundler) && Bundler.respond_to?(:with_unbundled_env)
                Bundler.with_unbundled_env(&run)
              else
                run.call
              end
  return true if succeeded
  return false unless raise_on_failure

  raise "#{dir}: #{command.join(" ")} failed"
end

def run_rake_task(dir, task, env: {})
  run_in_gem(dir, RbConfig.ruby, "-rbundler/setup", Gem.bin_path("rake", "rake"), task, env: env)
end

def bundle_command(*arguments)
  [RbConfig.ruby, Gem.bin_path("bundler", "bundle"), *arguments]
end

def bundle_contexts
  GEM_DIRS.flat_map do |dir|
    [{ dir: dir, gemfile: nil }] + CUSTOM_GEMFILES.fetch(dir, []).map { { dir: dir, gemfile: it } }
  end
end

def bundle_context_env(context)
  return {} unless context.fetch(:gemfile)

  { "BUNDLE_GEMFILE" => context.fetch(:gemfile) }
end

def bundle_context_label(context)
  context.fetch(:gemfile) || "Gemfile"
end

def gem_dir_supported?(dir)
  dir != "gems/ractor" || Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")
end

def bundle_context_supported?(context)
  gem_dir_supported?(context.fetch(:dir))
end

def each_supported_gem_dir(dirs = GEM_DIRS)
  dirs.each do |dir|
    unless gem_dir_supported?(dir)
      puts "\n==> #{dir}: skipped on Ruby #{RUBY_VERSION}"
      next
    end

    yield dir
  end
end

def assert_core_framework_neutrality
  Julewire::Quality::Boundaries.assert_core_neutrality(
    allowed_constants: CORE_ALLOWED_TOP_LEVEL_CONSTANTS,
    allowed_constants_by_path: CORE_ALLOWED_TOP_LEVEL_CONSTANTS_BY_PATH,
    core_public_alias_prefixes: CORE_PUBLIC_ALIAS_PREFIXES
  )
end

def assert_integration_core_boundaries
  Julewire::Quality::Boundaries.assert_integration_boundaries(
    integration_dirs: INTEGRATION_GEM_DIRS,
    integration_namespaces: INTEGRATION_NAMESPACES,
    integration_allowed_references: INTEGRATION_ALLOWED_REFERENCES,
    core_public_alias_prefixes: CORE_PUBLIC_ALIAS_PREFIXES,
    core_spi_allowed_prefixes: CORE_SPI_ALLOWED_PREFIXES,
    core_bridge_allowed_prefixes: CORE_BRIDGE_ALLOWED_PREFIXES
  )
end

def assert_safe_method_names
  Julewire::Quality::Boundaries.assert_safe_method_names(
    paths: Dir.glob(["gems/*/lib/**/*.rb", "support/**/*.rb"]),
    allowed_method_names: OBJECT_METHOD_NAME_ALLOWLIST
  )
end

def assert_api_tags
  Julewire::Quality::ApiTags.assert!(tag_values: API_TAG_VALUES, requirements: API_TAG_REQUIREMENTS)
end

def assert_release_metadata
  Julewire::Quality::ReleaseMetadata.assert!(gem_dirs: GEM_DIRS)
end

def gem_package_path(dir)
  Julewire::Quality::ReleaseMetadata.package_path(dir)
end

def mutant_gem_key(dir)
  File.basename(dir).tr("-", "_")
end

def mutant_runtime_subjects(dir)
  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby,
    "-rbundler/setup",
    Gem.bin_path("mutant", "mutant-ruby"),
    "environment",
    "subject",
    "list",
    chdir: dir
  )
  raise "could not inspect Mutant runtime subjects for #{dir}:\n#{stderr}" unless status.success?

  stdout.lines(chomp: true).select { |subject| subject.start_with?("Julewire") }
end

def production_flay_output(dir)
  output, status = Open3.capture2e(
    RbConfig.ruby,
    "-rbundler/setup",
    Gem.bin_path("flay", "flay"),
    "lib",
    chdir: dir
  )
  raise "Flay failed for #{dir}:\n#{output}" unless status.success?

  output
end

def production_flay_score(dir)
  output = production_flay_output(dir)
  score = output.each_line.filter_map do |line|
    Julewire::Quality::Flay::SCORE_PATTERN.match(line)&.captures&.first
  end.last
  return Integer(score, 10) if score

  raise "could not read Flay score for #{dir}:\n#{output}"
end

def mutant_command(subjects: [], since: nil)
  command = [
    RbConfig.ruby
  ]
  command.push(
    Gem.bin_path("bundler", "bundle"),
    "exec",
    RbConfig.ruby,
    Gem.bin_path("mutant", "mutant-ruby"),
    "run"
  )
  command.push("--since", since) if since
  command.push("--", *subjects) unless subjects.empty?
  command
end

def run_mutant_config(dir, subjects: [], since: nil, raise_on_failure: true)
  unless gem_dir_supported?(dir)
    puts "\n==> #{dir}: mutant skipped on Ruby #{RUBY_VERSION}"
    return
  end

  run_in_gem(dir, *mutant_command(subjects:, since:), env: MUTANT_COMMAND_ENV, raise_on_failure:)
end

def run_mutant_changes(dir, raise_on_failure: true)
  run_mutant_config(dir, since: ENV.fetch("SINCE_SHA", MUTANT_CHANGE_BASE), raise_on_failure:)
end

def run_mutant_changes_all
  failures = []
  each_supported_gem_dir do |dir|
    failures << dir unless run_mutant_changes(dir, raise_on_failure: false)
  end
  return if failures.empty?

  raise "mutant:changes failed for #{failures.join(", ")}"
end

namespace :all do
  desc "Run monorepo boundary checks"
  task :boundaries do
    assert_core_framework_neutrality
    assert_integration_core_boundaries
    assert_safe_method_names
  end

  desc "Check @api tag values"
  task(:api_tags) { assert_api_tags }

  desc "Run coverage-gated tests in every Julewire gem"
  task :coverage do
    each_supported_gem_dir { run_rake_task(it, "coverage") }
  end

  desc "Check production Flay scores against the approved baselines"
  task :flay do
    dirs = GEM_DIRS.select { gem_dir_supported?(it) }
    scores = dirs.to_h { |dir| [dir, production_flay_score(dir)] }
    Julewire::Quality::Flay.assert_baselines!(scores:, baselines: FLAY_PRODUCTION_BASELINES)
  end

  desc "Report duplicate production code in every Julewire gem"
  task :flay_production_report do
    GEM_DIRS.select { gem_dir_supported?(it) }.each do |dir|
      puts "#{dir}:\n#{production_flay_output(dir)}"
    end
  end

  desc "Report duplicate code across production and test files in every Julewire gem (diagnostic only)"
  task :flay_report do
    each_supported_gem_dir { run_rake_task(it, "flay") }
  end

  desc "Report potential unused production code in every Julewire gem"
  task :debride do
    each_supported_gem_dir { run_rake_task(it, "debride") }
  end

  desc "Run enforced static quality checks in every Julewire gem"
  task quality: %i[boundaries api_tags flay] do
    each_supported_gem_dir do |dir|
      QUALITY_TASKS.each { |task| run_rake_task(dir, task) }
    end
  end

  desc "Run bundler-audit in every Julewire gem"
  task :audit do
    each_supported_gem_dir { run_rake_task(it, "audit") }
  end
end

desc "Run Rails appraisal canaries"
task("all:rails_appraisal") { run_rake_task("gems/rails", "appraisal:test") }

desc "Run Semantic Logger appraisal canaries"
task("all:semantic_logger_appraisal") { run_rake_task("gems/semantic_logger", "appraisal:test") }

desc "Run coverage and static quality checks in every Julewire gem"
task "all:check" => %w[all:coverage all:quality]

desc "Run coverage, static quality, audit, appraisals, and changed mutation checks"
task "all:full" => %w[
  all:coverage all:quality all:audit all:rails_appraisal
  all:semantic_logger_appraisal mutant:changes
]

namespace :gems do
  desc "Update Bundler and all dependencies in every gem bundle"
  task :bump do
    bundle_contexts.each do |context|
      unless bundle_context_supported?(context)
        puts "\n==> #{context.fetch(:dir)} #{bundle_context_label(context)}: skipped on Ruby #{RUBY_VERSION}"
        next
      end

      env = bundle_context_env(context)
      label = bundle_context_label(context)
      BUNDLE_UPDATE_STEPS.each do |step|
        puts "\n==> #{context.fetch(:dir)} #{label}: bundle #{step.join(" ")}"
        run_in_gem(context.fetch(:dir), *bundle_command(*step), env: env)
      end
    end
  end
end

namespace :mutant do
  desc "Regenerate per-gem Mutant subject targets"
  task :targets do
    Julewire::Mutant::Targets.update!(
      gem_dirs: GEM_DIRS,
      namespaces: MUTANT_NAMESPACES,
      additional_subjects: MUTANT_ADDITIONAL_SUBJECTS
    )
  end

  namespace :targets do
    desc "Check per-gem Mutant subject targets are fresh"
    task :check do
      Julewire::Mutant::Targets.assert_visible_method_shapes!(
        gem_dirs: GEM_DIRS,
        allowed_class_body_define_method_counts: MUTANT_ALLOWED_CLASS_BODY_DEFINE_METHOD_COUNTS
      )
      Julewire::Mutant::Targets.assert_fresh!(
        gem_dirs: GEM_DIRS,
        namespaces: MUTANT_NAMESPACES,
        additional_subjects: MUTANT_ADDITIONAL_SUBJECTS
      )
    end

    desc "Check required subjects against each gem's loaded Mutant inventory"
    task :runtime do
      gem_dir = ENV.fetch("GEM_DIR", nil)
      requirements = if gem_dir
                       { gem_dir => MUTANT_REQUIRED_RUNTIME_SUBJECTS.fetch(gem_dir) }
                     else
                       MUTANT_REQUIRED_RUNTIME_SUBJECTS
                     end
      subject_lists = requirements.to_h do |dir, _subjects|
        [dir, mutant_runtime_subjects(dir)]
      end
      Julewire::Mutant::Targets.assert_runtime_subjects!(
        requirements: requirements,
        subject_lists: subject_lists
      )
    end
  end

  desc "Run configured mutation subjects changed since SINCE_SHA or HEAD~1"
  task :changes do
    run_mutant_changes_all
  end

  GEM_DIRS.each do |dir|
    gem_key = mutant_gem_key(dir)

    namespace gem_key do
      desc "Run configured mutation subjects changed since SINCE_SHA or HEAD~1 for #{dir}"
      task(:changes) { run_mutant_changes(dir) }
    end
  end
end

namespace :release do
  desc "Check monorepo release metadata"
  task(:check) { assert_release_metadata }
end

task default: "all:check"

local_rakefile = File.expand_path("Rakefile.local", __dir__)
load(local_rakefile) if File.file?(local_rakefile)
