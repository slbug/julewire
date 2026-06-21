# frozen_string_literal: true

require "bundler"
require "rbconfig"
require "fileutils"
require "prism"

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

QUALITY_TASKS = %w[rubocop flay debride].freeze
API_TAG_VALUES = %w[
  public
  extension
  integration_spi
  bridge_spi
  internal
].freeze
API_TAG_TARGET_PATTERN = /\A\s*(class|module|def)\b/
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
  "gems/core/lib/julewire/core/propagation/carrier.rb" => { "Carrier" => "public" },
  "gems/core/lib/julewire/core/records/console_formatter.rb" => { "ConsoleFormatter" => "extension" },
  "gems/core/lib/julewire/core/records/draft.rb" => { "Draft" => "extension" },
  "gems/core/lib/julewire/core/records/formatter.rb" => { "Formatter" => "extension" },
  "gems/core/lib/julewire/core/records/record.rb" => { "Record" => "extension" },
  "gems/core/lib/julewire/core/scheduling/deadline_scheduler.rb" => { "DeadlineScheduler" => "integration_spi" },
  "gems/core/lib/julewire/core/serialization/bounded_transform.rb" => { "BoundedTransform" => "integration_spi" },
  "gems/core/lib/julewire/core/serialization/json_encoder.rb" => { "JsonEncoder" => "extension" },
  "gems/core/lib/julewire/core/serialization/text_encoder.rb" => { "TextEncoder" => "extension" },
  "gems/core/lib/julewire/core/testing.rb" => {
    "CaptureDestination" => "extension",
    "NullOutput" => "extension",
    "Testing" => "extension"
  },
  "gems/core/lib/julewire/core/testing/chaos.rb" => { "Chaos" => "extension" },
  "gems/core/lib/julewire/core/testing/contracts.rb" => { "Contracts" => "extension" },
  "gems/core/lib/julewire/core/testing/coverage.rb" => { "Coverage" => "extension" },
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
  ENV
  Encoding
  EncodingError
  Enumerable
  Errno
  Exception
  Fiber
  File
  Float
  Hash
  IO
  Integer
  Interrupt
  JSON
  Kernel
  LoadError
  Module
  Mutex
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
  SimpleCov
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
].freeze
JULEWIRE_BAREWORD_PREFIXES = (INTEGRATION_NAMESPACES.values + CORE_PUBLIC_ALIAS_PREFIXES).to_h do |reference|
  [reference.split("::").last, reference]
end.freeze
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
  Core::Validation
].freeze
CORE_BRIDGE_ALLOWED_PREFIXES = %w[
  Core::ContextStore
  Core::Execution::Boundary
  Core::Execution::ScopeSnapshot
  Core::Execution::View
  Core::Records::LazyEmitInput
  Core::Serialization::Serializer
].freeze
CUSTOM_GEMFILES = {
  "gems/rails" => %w[
    gemfiles/rails_8_1.gemfile
    gemfiles/rails_head.gemfile
  ]
}.freeze
BUNDLE_UPDATE_STEPS = [
  %w[update --all],
  %w[update --bundler]
].freeze
MUTANT_REQUIRES = {
  "gems/active_job" => "julewire-active_job",
  "gems/core" => "julewire-core",
  "gems/gcp" => "julewire-gcp",
  "gems/karafka" => "julewire-karafka",
  "gems/rack" => "julewire-rack",
  "gems/ractor" => "julewire-ractor",
  "gems/rails" => "julewire-rails",
  "gems/rails_support" => "julewire-rails_support",
  "gems/redaction" => "julewire-redaction",
  "gems/semantic_logger" => "julewire-semantic_logger"
}.freeze
MUTANT_EXTRA_REQUIRES = {
  "gems/core" => ["julewire/core/testing"]
}.freeze
MUTANT_SUBJECTS = {
  "gems/active_job" => {
    primary: %w[
      Julewire::ActiveJob::JobAttributes
    ],
    extended: %w[
      Julewire::ActiveJob::LogSubscriberSilencer
    ]
  },
  "gems/core" => {
    primary: %w[
      Julewire::Core::Records::DisplayMessage
      Julewire::Core::Records::Record
      Julewire::Core::Serialization::BoundedTransform
      Julewire::Core::Processing::RecordFieldTransform
      Julewire::Core::Processing::Sampling
      Julewire::Core::Testing::Chaos.assert_contained
      Julewire::Core::Testing::Chaos.assert_discovered_chaos_contracts
      Julewire::Core::Testing::Chaos.assert_emitter_chaos_contract
      Julewire::Core::Testing::Chaos::Catalog.assert_contract
      Julewire::Core::Testing::Chaos::Destination.assert_contract
    ],
    extended: %w[
      Julewire::Core::CLI::Transcode
      Julewire::Core::Destinations::ChaosOutput
      Julewire::Core::Destinations::Definition
      Julewire::Core::Destinations::Destination
      Julewire::Core::Destinations::Registry
      Julewire::Core::Destinations::TailSampling
      Julewire::Core::Diagnostics::Doctor
      Julewire::Core::Diagnostics::FailureSnapshot
      Julewire::Core::Diagnostics::Health
      Julewire::Core::Diagnostics::Tail
      Julewire::Core::Execution::SummaryState
      Julewire::Core::Fields::StaticLabels
      Julewire::Core::Processing::ProcessorChain
      Julewire::Core::Processing::ProcessorWrapper
      Julewire::Core::Serialization::BacktraceLimiter
      Julewire::Core::Serialization::DeepCompactEmpty
      Julewire::Core::Serialization::DeepFreeze
      Julewire::Core::Serialization::ExceptionShape
      Julewire::Core::Serialization::JsonEncoder
      Julewire::Core::Serialization::TextEncoder
    ]
  },
  "gems/gcp" => {
    primary: %w[
      Julewire::GCP::ExecutionPayload
      Julewire::GCP::HttpRequestFields
      Julewire::GCP::SourceLocation
      Julewire::GCP::StackTrace
      Julewire::GCP::TraceContext
      Julewire::GCP::TraceContext::Traceparent
    ],
    extended: %w[
      Julewire::GCP::Destination
      Julewire::GCP::LabelFormatter
    ]
  },
  "gems/karafka" => {
    primary: %w[
      Julewire::Karafka::EventPayload
      Julewire::Karafka::MessagingAttributes
      Julewire::Karafka::PayloadReader
    ],
    extended: %w[
      Julewire::Karafka::EventSeverity
      Julewire::Karafka::MessageContext
      Julewire::Karafka::MessageExecution
      Julewire::Karafka::MonitorListener
      Julewire::Karafka::MonitorSubscription
      Julewire::Karafka::WaterdropMiddleware
    ]
  },
  "gems/rack" => {
    primary: %w[
      Julewire::Rack::Capture::BodyContentType
      Julewire::Rack::Capture::Headers
      Julewire::Rack::Capture::JsonBody
      Julewire::Rack::Capture::RequestBody
    ],
    extended: []
  },
  "gems/ractor" => {
    primary: %w[
      Julewire::Ractor::Bridge::RuntimeValidation
      Julewire::Ractor::Bridge::Stats
      Julewire::Ractor::RemotePayload
      Julewire::Ractor::RemoteSummaryRecord
    ],
    extended: %w[
      Julewire::Ractor::ChildStats
      Julewire::Ractor::Destination
      Julewire::Ractor::Fanout
      Julewire::Ractor::PortLifecycle
    ]
  },
  "gems/rails" => {
    primary: %w[
      Julewire::Rails::ExceptionSeverity
    ],
    extended: %w[
      Julewire::Rails::ContextBodyProxy
      Julewire::Rails::DoctorApp
      Julewire::Rails::Logger
      Julewire::Rails::ParameterFilterProcessor
      Julewire::Rails::RequestAttributes
      Julewire::Rails::RequestCompletion
      Julewire::Rails::RequestErrorOwnership
      Julewire::Rails::Subscribers::ControllerResponse
      Julewire::Rails::Subscribers::Error
      Julewire::Rails::Subscribers::Event
      Julewire::Rails::Subscribers::RenderedException
    ]
  },
  "gems/rails_support" => {
    primary: %w[
      Julewire::RailsSupport::EventReporter
    ],
    extended: []
  },
  "gems/redaction" => {
    primary: %w[
      Julewire::Redaction::Matcher
    ],
    extended: %w[
      Julewire::Redaction::Processor
      Julewire::Redaction::StringRedactor
    ]
  },
  "gems/semantic_logger" => {
    primary: %w[
      Julewire::SemanticLogger::ExactFormatter
    ],
    extended: %w[
      Julewire::SemanticLogger::AppenderHealth
      Julewire::SemanticLogger::Destination
      Julewire::SemanticLogger::LifecycleWarnings
      Julewire::SemanticLogger::Transport
    ]
  }
}.freeze

def run_in_gem(dir, *command, env: {}, raise_on_failure: true)
  puts "\n==> #{dir}: #{command.join(" ")}"
  run = proc { system(env, *command, chdir: dir) }
  succeeded = if defined?(Bundler) && Bundler.respond_to?(:with_unbundled_env)
                Bundler.with_unbundled_env(&run)
              elsif defined?(Bundler) && Bundler.respond_to?(:with_original_env)
                Bundler.with_original_env(&run)
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
  offenders = Dir.glob("gems/core/lib/**/*.rb").flat_map do |path|
    ruby_constant_references(path).filter_map do |reference, line|
      "#{path}:#{line}:#{reference}" if forbidden_core_constant_reference?(reference)
    end
  end
  return if offenders.empty?

  raise "core must use only core, stdlib, and declared dependency constants:\n#{offenders.join("\n")}"
end

def assert_integration_core_boundaries
  offenders = INTEGRATION_GEM_DIRS.flat_map do |dir|
    Dir.glob(File.join(dir, "lib/**/*.rb")).flat_map do |path|
      ruby_constant_references(path).flat_map do |reference, line|
        core_reference_offenders(dir, path, line, reference) +
          public_alias_offenders(dir, path, line, reference)
      end
    end
  end

  return if offenders.empty?

  raise "integration gems must use documented Core SPI:\n#{offenders.join("\n")}"
end

def assert_api_tags
  offenders = invalid_api_tag_offenders + missing_api_tag_offenders
  return if offenders.empty?

  raise "invalid @api tags:\n#{offenders.join("\n")}"
end

def invalid_api_tag_offenders
  Dir.glob("gems/*/lib/**/*.rb").flat_map do |path|
    lines = File.readlines(path, chomp: true)
    lines.filter_map.with_index(1) do |line, line_number|
      match = line.match(/#\s*@api\s+(\S+)/)
      next unless match

      tag = match[1]
      if !API_TAG_VALUES.include?(tag)
        "#{path}:#{line_number}:unknown #{tag}"
      elsif !api_tag_target?(lines, line_number)
        "#{path}:#{line_number}:not attached to class/module/def"
      end
    end
  end
end

def missing_api_tag_offenders
  API_TAG_REQUIREMENTS.flat_map do |path, requirements|
    tagged = api_tagged_targets(File.readlines(path, chomp: true))
    requirements.filter_map do |target, tag|
      next if tagged[target] == tag

      "#{path}:#{target}:missing @api #{tag}"
    end
  end
end

def api_tagged_targets(lines)
  lines.each_with_index.with_object({}) do |(line, index), targets|
    match = line.match(/#\s*@api\s+(\S+)/)
    next unless match

    target = api_tag_target_name(lines, index)
    targets[target] = match[1] if target
  end
end

def api_tag_target?(lines, line_number)
  lines[(line_number)..].each do |line|
    next if line.strip.empty? || line.lstrip.start_with?("#")

    return line.match?(API_TAG_TARGET_PATTERN)
  end
  false
end

def api_tag_target_name(lines, line_index)
  lines[(line_index + 1)..].each do |line|
    next if line.strip.empty? || line.lstrip.start_with?("#")

    return api_tag_definition_name(line)
  end
  nil
end

def api_tag_definition_name(line)
  match = line.match(/\A\s*(class|module)\s+([A-Z]\w*(?:::[A-Z]\w*)*)\b/)
  return unless match

  match[2].split("::").last
end

def ruby_constant_references(path)
  result = Prism.parse_file(path)
  unless result.success?
    errors = result.errors.map { "#{it.location.start_line}:#{it.message}" }.join("\n")
    raise "could not parse #{path}:\n#{errors}"
  end

  references = []
  collect_ruby_constant_references(result.value, references)
  longest_constant_references(references)
end

def ruby_constant_definitions(path)
  result = Prism.parse_file(path)
  unless result.success?
    errors = result.errors.map { "#{it.location.start_line}:#{it.message}" }.join("\n")
    raise "could not parse #{path}:\n#{errors}"
  end

  definitions = []
  collect_ruby_constant_definitions(result.value, definitions)
  definitions.uniq
end

def collect_ruby_constant_references(node, references)
  return unless node

  case node
  when Prism::ConstantPathNode, Prism::ConstantReadNode
    if (name = ruby_constant_name(node))
      references << [name, node.location.start_line]
    end
  end

  node.child_nodes.each { collect_ruby_constant_references(it, references) }
end

def collect_ruby_constant_definitions(node, definitions)
  return unless node

  case node
  when Prism::ClassNode, Prism::ModuleNode
    definitions << ruby_constant_name(node.constant_path) if node.respond_to?(:constant_path)
  when Prism::ConstantWriteNode
    definitions << node.name.to_s
  when Prism::ConstantPathWriteNode
    definitions << ruby_constant_name(node.target) if node.respond_to?(:target)
  end

  node.child_nodes.each { collect_ruby_constant_definitions(it, definitions) }
end

def ruby_constant_name(node)
  if node.respond_to?(:full_name)
    node.full_name
  else
    node.name.to_s
  end
end

def longest_constant_references(references)
  references.group_by(&:last).flat_map do |line, line_references|
    names = line_references.map(&:first).uniq
    names.reject { covered_by_longer_constant_reference?(it, names) }.map { [it, line] }
  end
end

def covered_by_longer_constant_reference?(reference, names)
  names.any? { it != reference && it.start_with?("#{reference}::") }
end

def forbidden_core_constant_reference?(reference)
  constant = reference.delete_prefix("::")
  return false if constant == "Julewire" || constant.start_with?("Julewire::Core")
  return false if constant == "Core" || constant.start_with?("Core::")

  root = constant.split("::", 2).first
  return false if CORE_ALLOWED_TOP_LEVEL_CONSTANTS.include?(root)
  return false if core_local_constant_roots.include?(root)

  true
end

def core_local_constant_roots
  @core_local_constant_roots ||= Dir.glob("gems/core/lib/**/*.rb").flat_map do |path|
    ruby_constant_definitions(path).map { it.to_s.delete_prefix("::").split("::", 2).first }
  end.uniq.freeze
end

def core_reference_offenders(dir, path, line, reference)
  core_reference = normalized_core_reference(reference)
  return [] unless core_reference
  return [] if allowed_core_reference?(dir, core_reference)

  ["#{path}:#{line}:#{core_reference}"]
end

def public_alias_offenders(dir, path, line, reference)
  julewire_public_references(reference).filter_map do |julewire_reference|
    next if julewire_reference.start_with?("Julewire::Core::")
    next if julewire_reference == "Julewire::Core"
    next if allowed_julewire_reference?(dir, julewire_reference)

    "#{path}:#{line}:#{julewire_reference}"
  end
end

def normalized_core_reference(reference)
  reference = reference.delete_prefix("::")
  if reference.start_with?("Julewire::Core::")
    reference.delete_prefix("Julewire::")
  elsif reference.start_with?("Core::")
    reference
  end
end

def allowed_core_reference?(dir, reference)
  allowed_core_prefix?(reference, CORE_SPI_ALLOWED_PREFIXES) ||
    (dir == "gems/ractor" && allowed_core_prefix?(reference, CORE_BRIDGE_ALLOWED_PREFIXES))
end

def allowed_julewire_reference?(dir, reference)
  allowed_core_prefix?(reference, [INTEGRATION_NAMESPACES.fetch(dir)]) ||
    allowed_core_prefix?(reference, INTEGRATION_ALLOWED_REFERENCES.fetch(dir, [])) ||
    allowed_core_prefix?(reference, CORE_PUBLIC_ALIAS_PREFIXES)
end

def julewire_public_references(reference)
  return [reference.delete_prefix("::")] if reference.start_with?("::Julewire::")
  return [reference] if reference.start_with?("Julewire::")
  return [] if reference.start_with?("::")

  root, suffix = reference.split("::", 2)
  prefix = JULEWIRE_BAREWORD_PREFIXES[root]
  return [] unless prefix

  [suffix ? "#{prefix}::#{suffix}" : prefix]
end

def allowed_core_prefix?(reference, prefixes)
  prefixes.any? { reference == it || reference.start_with?("#{it}::") }
end

def version_file_for(dir)
  Dir.glob(File.join(dir, "lib/julewire/**/version.rb")).fetch(0)
end

def version_for(dir)
  match = File.read(version_file_for(dir)).match(/VERSION = "([^"]+)"/)
  match && match[1]
end

def gemspec_for(dir)
  Dir.glob(File.join(dir, "*.gemspec")).fetch(0)
end

def gem_package_path(dir)
  version = version_for(dir)
  name = File.basename(gemspec_for(dir), ".gemspec")
  File.join("pkg", "#{name}-#{version}.gem")
end

def assert_release_metadata
  failures = []
  versions = GEM_DIRS.to_h do |dir|
    [dir, version_for(dir)]
  rescue IndexError, NoMethodError
    failures << "#{dir}: missing VERSION constant"
    [dir, nil]
  end

  release_versions = versions.values.compact.uniq
  failures << "gem versions differ: #{versions.inspect}" unless release_versions.one?

  GEM_DIRS.each { collect_release_metadata_failures(it, versions.fetch(it), failures) }

  return if failures.empty?

  raise "release metadata check failed:\n#{failures.join("\n")}"
end

def collect_release_metadata_failures(dir, version, failures)
  gemspec = File.read(gemspec_for(dir))
  changelog = File.read(File.join(dir, "CHANGELOG.md"))

  failures << "#{dir}: gemspec must package CHANGELOG.md" unless gemspec.include?('"CHANGELOG.md"')
  failures << "#{dir}: gemspec must expose changelog_uri" unless gemspec.include?('metadata["changelog_uri"]')
  failures << "#{dir}: CHANGELOG.md must have Unreleased" unless changelog.match?(/^## Unreleased$/)
  return unless version && !changelog.match?(/^## #{Regexp.escape(version)}(?:\s+-\s+\d{4}-\d{2}-\d{2})?$/)

  failures << "#{dir}: CHANGELOG.md must have version #{version}"
end

def mutant_gem_key(dir)
  File.basename(dir).tr("-", "_")
end

MUTANT_LIB_PATHS = GEM_DIRS.map { File.expand_path(File.join(it, "lib"), __dir__) }.freeze

def mutant_command(dir, require_name, subject)
  include_args = [*MUTANT_LIB_PATHS, File.expand_path(File.join(dir, "test"), __dir__)].flat_map do |path|
    ["--include", path]
  end
  require_args = [require_name, *MUTANT_EXTRA_REQUIRES.fetch(dir, [])].flat_map do |path|
    ["--require", path]
  end

  [
    RbConfig.ruby,
    Gem.bin_path("bundler", "bundle"),
    "exec",
    "mutant-ruby",
    "run",
    "--usage",
    "opensource",
    "--integration",
    "minitest",
    *include_args,
    "--require",
    "mutant",
    "--require",
    File.expand_path("support/mutant/ruby_itblock", __dir__),
    *require_args,
    "--",
    subject
  ]
end

def run_mutant_subjects(dir, tier)
  unless gem_dir_supported?(dir)
    puts "\n==> #{dir}: mutant #{tier} skipped on Ruby #{RUBY_VERSION}"
    return
  end

  subjects = MUTANT_SUBJECTS.fetch(dir).fetch(tier)
  return if subjects.empty?

  require_name = MUTANT_REQUIRES.fetch(dir)
  clean = []
  failures = []
  subjects.each do |subject|
    success = run_in_gem(dir, *mutant_command(dir, require_name, subject), raise_on_failure: tier != :extended)
    success ? clean << subject : failures << subject
  end

  return report_extended_mutant_subjects(dir, clean, failures) if tier == :extended

  raise "#{dir}: mutant #{tier} failed for #{failures.join(", ")}" unless failures.empty?
end

def report_extended_mutant_subjects(dir, clean, failures)
  puts "#{dir}: mutant extended clean subjects: #{clean.join(", ")}" unless clean.empty?
  puts "#{dir}: mutant extended open subjects: #{failures.join(", ")}" unless failures.empty?
end

namespace :all do
  desc "Run monorepo boundary checks"
  task :boundaries do
    assert_core_framework_neutrality
    assert_integration_core_boundaries
  end

  desc "Check @api tag values"
  task(:api_tags) { assert_api_tags }

  desc "Run coverage-gated tests in every Julewire gem"
  task :coverage do
    each_supported_gem_dir { run_rake_task(it, "coverage") }
  end

  desc "Run static quality checks in every Julewire gem"
  task quality: %i[boundaries api_tags] do
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

desc "Run coverage and static quality checks in every Julewire gem"
task "all:check" => %w[all:coverage all:quality]

desc "Run coverage, static quality, audit, Rails appraisal, and primary mutation checks"
task "all:full" => %w[all:coverage all:quality all:audit all:rails_appraisal mutant:all]

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
  desc "Run primary mutation subjects in every gem"
  task :all do
    MUTANT_SUBJECTS.each_key { run_mutant_subjects(it, :primary) }
  end

  desc "Run extended mutation subjects in every gem"
  task :extended do
    MUTANT_SUBJECTS.each_key { run_mutant_subjects(it, :extended) }
  end

  desc "Run primary and extended mutation subjects in every gem"
  task full: %i[all extended]

  MUTANT_SUBJECTS.each_key do |dir|
    gem_key = mutant_gem_key(dir)

    desc "Run primary mutation subjects for #{dir}"
    task(gem_key) { run_mutant_subjects(dir, :primary) }

    namespace gem_key do
      desc "Run extended mutation subjects for #{dir}"
      task(:extended) { run_mutant_subjects(dir, :extended) }

      desc "Run primary and extended mutation subjects for #{dir}"
      task(:all) do
        run_mutant_subjects(dir, :primary)
        run_mutant_subjects(dir, :extended)
      end
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
