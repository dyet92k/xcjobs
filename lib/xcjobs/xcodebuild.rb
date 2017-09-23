require 'rake/tasklib'
require 'rake/clean'
require 'open3'
require 'shellwords'
require 'securerandom'
require_relative 'helper'

module XCJobs
  class Xcodebuild < Rake::TaskLib
    include Rake::DSL if defined?(Rake::DSL)

    attr_accessor :name
    attr_accessor :description
    attr_accessor :project
    attr_accessor :target
    attr_accessor :workspace
    attr_accessor :scheme
    attr_accessor :sdk
    attr_accessor :configuration
    attr_accessor :signing_identity
    attr_accessor :provisioning_profile
    attr_accessor :build_dir
    attr_accessor :coverage
    attr_accessor :formatter
    attr_accessor :hide_shell_script_environment

    attr_reader :destinations
    attr_reader :provisioning_profile_name
    attr_reader :provisioning_profile_uuid

    attr_accessor :unsetenv_others

    def initialize(name)
      $stdout.sync = $stderr.sync = true

      @name = name
      @destinations = []
      @only_testings = []
      @skip_testings = []
      @build_options = {}
      @build_settings = {}
      @unsetenv_others = false
      @description = Rake.application.last_description # nil or given from "desc"
    end

    def project
      if @project
        File.extname(@project).empty? ? "#{@project}.xcodeproj" : @project
      end
    end

    def workspace
      if @workspace
        File.extname(@workspace).empty? ? "#{@workspace}.xcworkspace" : @workspace
      end
    end

    def coverage_enabled
      @coverage
    end

    def before_action(&block)
      @before_action = block
    end

    def after_action(&block)
      @after_action = block
    end

    def provisioning_profile=(provisioning_profile)
      @provisioning_profile = provisioning_profile
      @provisioning_profile_path, @provisioning_profile_uuid, @provisioning_profile_name = XCJobs::Helper.extract_provisioning_profile(provisioning_profile)
    end

    def add_destination(destination)
      @destinations << destination
    end

    def add_only_testing(only_testing)
      @only_testings << only_testing
    end

    def add_skip_testing(skip_testing)
      @skip_testings << skip_testing
    end

    def add_build_option(option, value)
      @build_options[option] = value
    end

    def add_build_setting(setting, value)
      @build_settings[setting] = value
    end

    private

    def run(cmd)
      @before_action.call if @before_action

      if @formatter
        puts (cmd + ['|', @formatter]).join(" ")
      else
        puts cmd.join(" ")
      end

      env = { "NSUnbufferedIO" => "YES" }
      options = { unsetenv_others: unsetenv_others }

      if @formatter
        Open3.pipeline_r([env] + cmd + [options], [@formatter]) do |stdout, wait_thrs|
          output = []
          while line = stdout.gets
            puts line
            output << line
          end

          status = wait_thrs.first.value
          if status.success?
            @after_action.call(output, status) if @after_action
          else
            fail "xcodebuild failed (exited with status: #{status.exitstatus})"
          end
        end
      else
        Open3.popen2e(env, *cmd, options) do |stdin, stdout_err, wait_thr|
          output = []
          while line = stdout_err.gets
            puts line
            output << line
          end

          status = wait_thr.value
          if status.success?
            @after_action.call(output, status) if @after_action
          else
            fail "xcodebuild failed (exited with status: #{status.exitstatus})"
          end
        end
      end
    end

    def options
      [].tap do |opts|
        opts.concat(['-project', project]) if project
        opts.concat(['-target', target]) if target
        opts.concat(['-workspace', workspace]) if workspace
        opts.concat(['-scheme', scheme]) if scheme
        opts.concat(['-sdk', sdk]) if sdk
        opts.concat(['-configuration', configuration]) if configuration
        opts.concat(['-enableCodeCoverage', 'YES']) if coverage_enabled
        opts.concat(['-derivedDataPath', build_dir]) if build_dir
        opts.concat(['-hideShellScriptEnvironment']) if hide_shell_script_environment

        @destinations.each do |destination|
          opts.concat(['-destination', destination])
        end

        @only_testings.each do |only_testing|
          opts.concat(["-only-testing:#{only_testing}"])
        end
        @skip_testings.each do |skip_testing|
          opts.concat(["-skip-testing:#{skip_testing}"])
        end

        @build_options.each do |option, value|
          opts.concat([option, value])
        end
        @build_settings.each do |setting, value|
          opts << "#{setting}=#{value}"
        end
      end
    end
  end

  class Test < Xcodebuild
    attr_accessor :without_building

    def initialize(name = :test)
      super
      @description ||= 'test application'
      @without_building = false
      yield self if block_given?
      define
    end

    def sdk
      @sdk || 'iphonesimulator'
    end

    private

    def build_settings(options)
      out, status = Open3.capture2(*(['xcodebuild', 'test'] + options + ['-showBuildSettings']))

      settings, target = {}, nil
      out.lines.each do |line|
        case line
        when /Build settings for action test and target (.+):/
          target = $1
          settings[target] = {}
        else
          key, value = line.split(/\=/).collect(&:strip)
          settings[target][key] = value if target
        end
      end
      return settings
    end

    def define
      raise 'test action requires specifying a scheme' unless scheme
      raise 'cannot specify both a scheme and targets' if scheme && target

      desc @description
      task @name do
        add_build_setting('GCC_SYMBOLS_PRIVATE_EXTERN', 'NO')

        run(['xcodebuild', command] + options)
      end
    end

    def command
      'test'
    end
  end

  class Build < Xcodebuild
    def initialize(name = :build)
      super
      @description ||= 'build application'
      yield self if block_given?
      define
    end

    private

    def define
      raise 'the scheme is required when specifying build_dir' if build_dir && !scheme
      raise 'cannot specify both a scheme and targets' if scheme && target

      CLEAN.include(build_dir) if build_dir
      CLOBBER.include(build_dir) if build_dir

      desc @description
      task @name do
        add_build_setting('CONFIGURATION_TEMP_DIR', File.join(build_dir, 'temp')) if build_dir
        add_build_setting('CODE_SIGN_IDENTITY', signing_identity) if signing_identity
        add_build_setting('PROVISIONING_PROFILE', provisioning_profile_uuid) if provisioning_profile_uuid

        run(['xcodebuild', command] + options)
      end
    end

    def command
      'build'
    end
  end

  class TestWithoutBuilding < Build
    private

    def command
      'test-without-building'
    end
  end

  class BuildForTesting < Build
    private

    def command
      'build-for-testing'
    end
  end

  class Archive < Xcodebuild
    attr_accessor :archive_path

    def initialize(name = :archive)
      super
      @description ||= 'make xcarchive'
      yield self if block_given?
      define
    end

    private

    def define
      raise 'archive action requires specifying a scheme' unless scheme
      raise 'cannot specify both a scheme and targets' if scheme && target

      if build_dir
        CLEAN.include(build_dir)
        CLOBBER.include(build_dir)
      end

      desc @description
      namespace :build do
        task @name do
          add_build_setting('CONFIGURATION_TEMP_DIR', File.join(build_dir, 'temp')) if build_dir
          add_build_setting('CODE_SIGN_IDENTITY', signing_identity) if signing_identity
          add_build_setting('PROVISIONING_PROFILE', provisioning_profile_uuid) if provisioning_profile_uuid

          run(['xcodebuild', 'archive'] + options)

          if build_dir && scheme
            bd = build_dir.shellescape
            s = scheme.shellescape
            sh %[(cd #{bd}; zip -ryq dSYMs.zip #{File.join("#{s}.xcarchive", "dSYMs")})]
            sh %[(cd #{bd}; zip -ryq #{s}.xcarchive.zip #{s}.xcarchive)]
          end
        end
      end
    end

    def archive_path
      @archive_path || (build_dir && scheme ? File.join(build_dir, scheme) : nil)
    end

    def options
      super.tap do |opts|
        opts.concat(['-archivePath', archive_path]) if archive_path
      end
    end
  end

  class Export < Xcodebuild
    attr_accessor :archive_path
    attr_accessor :export_format
    attr_accessor :export_path
    attr_accessor :export_provisioning_profile
    attr_accessor :export_signing_identity
    attr_accessor :export_installer_identity
    attr_accessor :export_with_original_signing_identity
    attr_accessor :options_plist

    def initialize(name = :export)
      super
      self.unsetenv_others = true
      @description ||= 'export from an archive'
      @export_format = 'IPA'
      yield self if block_given?
      define
    end

    def archive_path
      @archive_path || (build_dir && scheme ? File.join(build_dir, scheme) : nil)
    end

    def export_format
      @export_format
    end

    def export_provisioning_profile=(provisioning_profile)
      provisioning_profile_path, provisioning_profile_uuid, provisioning_profile_name = XCJobs::Helper.extract_provisioning_profile(provisioning_profile)
      if provisioning_profile_name
        @export_provisioning_profile = provisioning_profile_name
      else
        @export_provisioning_profile = provisioning_profile
      end
    end

    private

    def define
      desc @description
      namespace :build do
        task name do
          run(['xcodebuild', '-exportArchive'] + options)
        end
      end
    end

    def options
      [].tap do |opts|
        opts.concat(['-exportOptionsPlist', options_plist]) if options_plist
        opts.concat(['-archivePath', archive_path]) if archive_path
        opts.concat(['-exportFormat', export_format])  if export_format
        opts.concat(['-exportPath', export_path]) if export_path
        opts.concat(['-exportProvisioningProfile', export_provisioning_profile]) if export_provisioning_profile
        opts.concat(['-exportSigningIdentity', export_signing_identity]) if export_signing_identity
        opts.concat(['-exportInstallerIdentity', export_installer_identity]) if export_installer_identity
        opts.concat(['-exportWithOriginalSigningIdentity']) if export_with_original_signing_identity
      end
    end
  end
end
