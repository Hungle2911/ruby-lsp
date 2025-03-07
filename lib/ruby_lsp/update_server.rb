# typed: true
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
      attr_reader :gem_name, :constraint, :available_version

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

    sig { return(T::Boolean) }
    def update!
      unless @custom_dir.exist? && @custom_gemfile.exist?
        puts "Error: No composed Ruby LSP bundle found. Run the Ruby LSP server to set it up first"
        false
      end

      puts "Updating Ruby LSP server dependencies..."
    end
  end
end
