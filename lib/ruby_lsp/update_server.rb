# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "bundler"
require "bundler/cli"
require "bundler/cli/update"
require "fileutils"
require "pathname"
require "optparse"

module RubyLsp
  class UpdateServer
    extend T::Sig

    class UpdateFailure < StandardError; end

    class DependencyConstraintError < StandardError
      #: String
      attr_reader :gem_name
      #: String
      attr_reader :constraint
      #: String
      attr_reader :available_version

      #: (String gem_name, String constraint, String available_version) -> void
      def initialize(gem_name, constraint, available_version)
        @gem_name = gem_name
        @constraint = constraint
        @available_version = available_version
        super("Unable to update #{gem_name} due to version constraint: #{constraint}.
        Latest available version: #{available_version} ")
      end
    end

    sig { params(project_path: String, options: T::Hash[Symbol, T.untyped]).void }
    def initialize(project_path, options = {})
      @project_path = project_path

      # Custom bundle paths
      @custom_dir = T.let(Pathname.new(".ruby-lsp").expand_path(@project_path), Pathname)
      @gemfile = T.let(
        begin
          Bundler.default_gemfile
        rescue Bundler::GemfileNotFound
          nil
        end,
        T.nilable(Pathname),
      )
      @gemfile_name = T.let(@gemfile&.basename&.to_s || "Gemfile", String)
      @custom_gemfile = T.let(@custom_dir + @gemfile_name, Pathname)
    end

    sig { returns(T.untyped) }
    def update!
      unless @custom_dir.exist? && @custom_gemfile.exist?
        puts "Error: No composed Ruby LSP bundle found. Run the Ruby LSP server to set it up first"
        false
      end

      puts "Updating Ruby LSP server dependencies..."
      env = bundler_settings_as_env
      env["BUNDLE_GEMFILE"] = @custom_gemfile.to_s

      convert_paths_to_absolute!(env)

      bundler_version = retrieve_bundler_version
      if bundler_version
        env["BUNDLER_VERSION"] = bundler_version.to_s
        puts "Using Bundler version: #{bundler_version}"
      end

      begin
        update_result = run_bundle_update(env)
        puts "Ruby LSP server dependencies successfully updated!"
        update_result
      rescue DependencyConstraintError => e
        puts "Error: #{e.message}"
        puts "The gem '#{e.gem_name}' in your project is preventing the update due to constraint: #{e.constraint}"
        puts "The latest available version is: #{e.available_version}"
        false
      rescue UpdateFailure => e
        puts "Error updating Ruby LSP server dependencies: #{e.message}"
        false
      end
    end

    private

    sig { params(env: T::Hash[String, String]).returns(T::Boolean) }
    def run_bundle_update(env)
      original_env = ENV.to_h
      begin
        # Replace the environment
        ENV.replace(original_env.merge(env))

        puts "Using environment:"
        env.each { |k, v| puts "  #{k}=#{v}" }

        # Run bundle update for ruby-lsp and its dependencies
        gems = ["ruby-lsp", "ruby-lsp-rails", "debug", "prism"]

        # Add branch specification if provided
        update_options = { conservative: true }

        puts "Updating gems: #{gems.join(", ")}"

        output = capture_bundler_output do
          Bundler.settings.temporary(frozen: false) do
            Bundler::CLI::Update.new(update_options, gems).run
          end
        end

        puts output

        # Check if the update succeeded by looking for the "Bundle updated!" message
        return true if output.include?("Bundle updated!")

        # If we get here without a success message, something went wrong
        # Try to identify dependency constraint issues
        detect_constraint_issues(output)

        # If no specific issue was found, raise a generic error
        raise UpdateFailure, "Update failed."
      rescue Bundler::GemNotFound => e
        raise UpdateFailure, "Gem not found: #{e.message}"
      rescue Bundler::GitError => e
        raise UpdateFailure, "Git error: #{e.message}"
      rescue Bundler::VersionConflict => e
        raise UpdateFailure, "Version conflict: #{e.message}"
      ensure
        # Restore the original environment
        ENV.replace(original_env)
      end
    end

    sig { params(output: String).void }
    def detect_constraint_issues(output)
      # Look for constraint messages in the output
      output.scan(/Bundler could not find compatible versions for gem "([\w\-]+)".*?Required by.*?(\S+).*?The latest version is ([\d\.]+)/).each do |match| # rubocop:disable Layout/LineLength
        next unless match.is_a?(Array) && match.length >= 3

        gem_name, constraint, latest_version = match
        if gem_name.is_a?(String) && constraint.is_a?(String) && latest_version.is_a?(String)
          raise DependencyConstraintError.new(gem_name, constraint, latest_version)
        end
      end
    end

    sig { params(block: T.proc.void).returns(String) }
    def capture_bundler_output(&block)
      original_stdout = $stdout
      original_stderr = $stderr
      output_capture = StringIO.new
      begin
        $stdout = output_capture
        $stderr = output_capture
        yield
        output_capture.string
      ensure
        $stdout = original_stdout
        $stderr = original_stderr
      end
    end

    sig { returns(T::Hash[String, String]) }
    def bundler_settings_as_env
      local_config_path = File.join(@project_path, ".bundle")
      # Get all Bundler settings (global and local)
      settings = begin
        Dir.exist?(local_config_path) ? Bundler::Settings.new(local_config_path) : Bundler::Settings.new
      rescue Bundler::GemfileNotFound
        Bundler::Settings.new
      end

      # Convert settings to environment variables
      settings.all.to_h do |e|
        key = settings.key_for(e)
        value = Array(settings[e]).join(":").tr(" ", ":")
        [key, value]
      end
    end

    sig { params(env: T::Hash[String, String]).void }
    def convert_paths_to_absolute!(env)
      env.each do |key, value|
        next unless key.start_with?("BUNDLE_") && key.end_with?("_PATH", "PATH")
        next if value.start_with?("/") # Skip if already absolute

        # Convert relative path to absolute
        env[key] = File.expand_path(value, @project_path)
        puts "Converting #{key}=#{value} to #{env[key]}"
      end
    end

    sig { returns(T.nilable(Gem::Version)) }
    def retrieve_bundler_version
      return unless @gemfile

      lockfile = @gemfile.dirname + "Gemfile.lock"
      return unless lockfile.exist?

      Bundler::LockfileParser.new(lockfile.read).bundler_version
    rescue => e
      puts "Warning: Unable to determine Bundler version: #{e.message}"
      nil
    end
  end
end
