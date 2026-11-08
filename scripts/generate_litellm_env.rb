#!/usr/bin/env ruby
# Convert the LITELLM_CONFIG YAML secret into a least-privilege LiteLLM env file.
# Values are never written to stdout or GitHub step outputs.

require "optparse"
require "uri"
require "yaml"

REQUIRED_CONFIG_KEYS = %w[
  VPS_HOST
  LITELLM_MASTER_KEY
  POSTGRES_USER
  POSTGRES_PASSWORD
  OPENAI_API_KEY
  ANTHROPIC_API_KEY
  DEEPSEEK_API_KEY
  DASHSCOPE_API_KEY
].freeze

RUNTIME_KEYS = %w[
  LITELLM_MASTER_KEY
  LITELLM_SALT_KEY
  OPENAI_API_KEY
  ANTHROPIC_API_KEY
  DEEPSEEK_API_KEY
  DASHSCOPE_API_KEY
  POSTGRES_USER
  POSTGRES_PASSWORD
  UI_USERNAME
  UI_PASSWORD
  STORE_MODEL_IN_DB
].freeze

options = { ssh_user: "root" }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/generate_litellm_env.rb --output PATH [--input YAML] [--github-output PATH]"
  parser.on("--input PATH", "Read YAML from a local file instead of LITELLM_CONFIG") { |value| options[:input] = value }
  parser.on("--output PATH", "Write the generated env file (mode 0600)") { |value| options[:output] = value }
  parser.on("--github-output PATH", "Write non-secret VPS_HOST/SSH_USER step outputs") { |value| options[:github_output] = value }
end.parse!

unless options[:output]
  warn "[env] --output is required"
  exit 2
end

begin
  yaml_text = options[:input] ? File.read(options[:input]) : ENV.fetch("LITELLM_CONFIG")
  config = YAML.safe_load(yaml_text, permitted_classes: [], permitted_symbols: [], aliases: false)
  raise "top level must be a mapping" unless config.is_a?(Hash)

  config = config.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
  missing = REQUIRED_CONFIG_KEYS.select { |key| config[key].nil? || config[key].to_s.empty? }
  raise "missing required keys: #{missing.join(', ')}" unless missing.empty?
  invalid_types = REQUIRED_CONFIG_KEYS.reject { |key| config[key].is_a?(String) }
  raise "required values must be strings: #{invalid_types.join(', ')}" unless invalid_types.empty?

  host = config.fetch("VPS_HOST").to_s
  raise "VPS_HOST contains unsupported characters" unless host.match?(/\A[A-Za-z0-9][A-Za-z0-9.:%-]*\z/)

  ssh_user = config.fetch("SSH_USER", "root").to_s
  raise "SSH_USER must be a string" unless config.fetch("SSH_USER", "root").is_a?(String)
  raise "SSH_USER is invalid" unless ssh_user.match?(/\A[A-Za-z_][A-Za-z0-9_.-]*\$?\z/)

  env = {}
  RUNTIME_KEYS.each do |key|
    next unless config.key?(key) && !config[key].nil?

    value = config[key]
    unless value.is_a?(String) || (key == "STORE_MODEL_IN_DB" && (value == true || value == false))
      raise "#{key} must be a string"
    end
    value = value.to_s
    next if value.empty?
    raise "#{key} must not contain NUL" if value.include?("\0")
    raise "#{key} must be a single-line value" if value.include?("\n") || value.include?("\r")
    raise "#{key} cannot contain a backslash before a single quote" if value.include?("\\'")
    raise "#{key} cannot end with a backslash" if value.end_with?("\\")

    env[key] = value
  end

  url_escape = ->(value) { URI::DEFAULT_PARSER.escape(value.to_s, /[^A-Za-z0-9._~-]/) }
  env["LITELLM_DATABASE_URL"] =
    "postgresql://#{url_escape.call(env.fetch('POSTGRES_USER'))}:#{url_escape.call(env.fetch('POSTGRES_PASSWORD'))}@postgres:5432/litellm"

  File.open(options[:output], File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
    # Compose treats single-quoted env-file values literally, including '$'.
    # Escape single quotes using Compose's dotenv syntax instead of JSON quoting.
    env.each do |key, value|
      escaped_value = value.gsub("'") { |quote| "\\#{quote}" }
      file.puts("#{key}='#{escaped_value}'")
    end
  end
  File.chmod(0o600, options[:output])

  if options[:github_output]
    File.open(options[:github_output], "a") do |file|
      file.puts("vps_host=#{host}")
      file.puts("ssh_user=#{ssh_user}")
    end
  end

  puts "[env] generated restricted LiteLLM env file; values were not logged"
rescue KeyError
  warn "[env] LITELLM_CONFIG is not set"
  exit 1
rescue Psych::Exception, ArgumentError, RuntimeError, URI::InvalidURIError => error
  # Do not print parser exceptions: malformed YAML diagnostics can contain source text.
  message = error.message.start_with?("missing required keys:") ? error.message : "invalid YAML/configuration"
  warn "[env] #{message}"
  exit 1
end
