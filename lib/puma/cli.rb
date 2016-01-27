require 'optparse'
require 'uri'

require 'puma/server'
require 'puma/const'
require 'puma/configuration'
require 'puma/binder'
require 'puma/detect'
require 'puma/daemon_ext'
require 'puma/util'
require 'puma/single'
require 'puma/cluster'

require 'puma/commonlogger'
require 'puma/launcher'

module Puma
  class << self
    # The CLI exports its Puma::Configuration object here to allow
    # apps to pick it up. An app needs to use it conditionally though
    # since it is not set if the app is launched via another
    # mechanism than the CLI class.
    attr_accessor :cli_config
  end

  # Handles invoke a Puma::Server in a command line style.
  #
  class CLI
    # Create a new CLI object using +argv+ as the command line
    # arguments.
    #
    # +stdout+ and +stderr+ can be set to IO-like objects which
    # this object will report status on.
    #
    def initialize(argv, events=Events.stdio)
      @debug = false
      @argv = argv

      @events = events

      @status = nil
      @runner = nil

      @config = nil

      ENV['NEWRELIC_DISPATCHER'] ||= "Puma"

      setup_options
      generate_restart_data

      @binder = Binder.new(@events)
      @binder.import_from_env

      begin
        @parser.parse! @argv
        @cli_options[:rackup] = @argv.shift if @argv.last
      rescue UnsupportedOption
        exit 1
      end

      @launcher = Puma::Launcher.new(@cli_options)

      @launcher.events  = self.events
      @launcher.config  = self.config
      @launcher.binder  = self.binder
      @launcher.setup(@options)
    end

    ## start BACKWARDS COMPAT

    def delete_pidfile
      @launcher.delete_pidfile
    end

    def log(string)
      @launcher.log(string)
    end

    def stop
      @launcher.stop
    end

    def restart
      @launcher.restart
    end

    def write_state
      @launcher.write_state
    end

    def write_pid
      @launcher.write_pid
    end

    def error(str)
      @launcher.error(str)
    end

    def debug(str)
      @launcher.debug(str)
    end

  private
    def parse_options
      @launcher.send(:parse_options)
    end

    def set_rack_environment
      @launcher.send(:set_rack_environment)
    end

    def restart_args
      @launcher.restart_args
    end
  public

    ## end BACKWARDS COMPAT

    # The Binder object containing the sockets bound to.
    attr_reader :binder

    # The Configuration object used.
    attr_reader :config

    # The Hash of options used to configure puma.
    attr_reader :options

    # The Events object used to output information.
    attr_reader :events


    def clustered?
      @launcher.clustered?
    end

    def jruby_daemon_start
      @launcher.jruby_daemon_start
    end

    def restart!
      @launcher.restart!
    end

    # Parse the options, load the rackup, start the server and wait
    # for it to finish.
    #
    def run
      @runner = @launcher.runner
      @launcher.run
    end

    def reload_worker_directory
      @runner.reload_worker_directory if @runner.respond_to?(:reload_worker_directory)
    end

    def phased_restart
      unless @runner.respond_to?(:phased_restart) and @runner.phased_restart
        log "* phased-restart called but not available, restarting normally."
        return restart
      end
      true
    end

    def redirect_io
      @runner.redirect_io
    end

    def stats
      @launcher.stats
    end

    def halt
      @status = :halt
      @runner.halt
    end


    def jruby?
      Puma.jruby?
    end

    def windows?
      Puma.windows?
    end

  private
    def unsupported(str)
      @events.error(str)
      raise UnsupportedOption
    end

    # Build the OptionParser object to handle the available options.
    #

    def setup_options
      @cli_options = {}
      @options = {}

      @parser = OptionParser.new do |o|
        o.on "-b", "--bind URI", "URI to bind to (tcp://, unix://, ssl://)" do |arg|
          (@cli_options[:binds] ||= []) << arg
        end

        o.on "-C", "--config PATH", "Load PATH as a config file" do |arg|
          @cli_options[:config_file] = arg
        end

        o.on "--control URL", "The bind url to use for the control server",
                              "Use 'auto' to use temp unix server" do |arg|
          if arg
            @cli_options[:control_url] = arg
          elsif jruby?
            unsupported "No default url available on JRuby"
          end
        end

        o.on "--control-token TOKEN",
             "The token to use as authentication for the control server" do |arg|
          @cli_options[:control_auth_token] = arg
        end

        o.on "-d", "--daemon", "Daemonize the server into the background" do
          @cli_options[:daemon] = true
          @cli_options[:quiet] = true
        end

        o.on "--debug", "Log lowlevel debugging information" do
          @cli_options[:debug] = true
        end

        o.on "--dir DIR", "Change to DIR before starting" do |d|
          @cli_options[:directory] = d.to_s
          @cli_options[:worker_directory] = d.to_s
        end

        o.on "-e", "--environment ENVIRONMENT",
             "The environment to run the Rack app on (default development)" do |arg|
          @cli_options[:environment] = arg
        end

        o.on "-I", "--include PATH", "Specify $LOAD_PATH directories" do |arg|
          $LOAD_PATH.unshift(*arg.split(':'))
        end

        o.on "-p", "--port PORT", "Define the TCP port to bind to",
                                  "Use -b for more advanced options" do |arg|
          binds = (@cli_options[:binds] ||= [])
          binds << "tcp://#{Configuration::DefaultTCPHost}:#{arg}"
        end

        o.on "--pidfile PATH", "Use PATH as a pidfile" do |arg|
          @cli_options[:pidfile] = arg
        end

        o.on "--preload", "Preload the app. Cluster mode only" do
          @cli_options[:preload_app] = true
        end

        o.on "--prune-bundler", "Prune out the bundler env if possible" do
          @cli_options[:prune_bundler] = true
        end

        o.on "-q", "--quiet", "Quiet down the output" do
          @cli_options[:quiet] = true
        end

        o.on "-R", "--restart-cmd CMD",
             "The puma command to run during a hot restart",
             "Default: inferred" do |cmd|
          @cli_options[:restart_cmd] = cmd
        end

        o.on "-S", "--state PATH", "Where to store the state details" do |arg|
          @cli_options[:state] = arg
        end

        o.on '-t', '--threads INT', "min:max threads to use (default 0:16)" do |arg|
          min, max = arg.split(":")
          if max
            @cli_options[:min_threads] = min
            @cli_options[:max_threads] = max
          else
            @cli_options[:min_threads] = 0
            @cli_options[:max_threads] = arg
          end
        end

        o.on "--tcp-mode", "Run the app in raw TCP mode instead of HTTP mode" do
          @cli_options[:mode] = :tcp
        end

        o.on "-V", "--version", "Print the version information" do
          puts "puma version #{Puma::Const::VERSION}"
          exit 0
        end

        o.on "-w", "--workers COUNT",
                   "Activate cluster mode: How many worker processes to create" do |arg|
          @cli_options[:workers] = arg.to_i
        end

        o.on "--tag NAME", "Additional text to display in process listing" do |arg|
          @cli_options[:tag] = arg
        end

        o.on "--redirect-stdout FILE", "Redirect STDOUT to a specific file" do |arg|
          @cli_options[:redirect_stdout] = arg
        end

        o.on "--redirect-stderr FILE", "Redirect STDERR to a specific file" do |arg|
          @cli_options[:redirect_stderr] = arg
        end

        o.on "--[no-]redirect-append", "Append to redirected files" do |val|
          @cli_options[:redirect_append] = val
        end

        o.banner = "puma <options> <rackup file>"

        o.on_tail "-h", "--help", "Show help" do
          log o
          exit 0
        end
      end
    end

    def generate_restart_data
      # Use the same trick as unicorn, namely favor PWD because
      # it will contain an unresolved symlink, useful for when
      # the pwd is /data/releases/current.
      if dir = ENV['PWD']
        s_env = File.stat(dir)
        s_pwd = File.stat(Dir.pwd)

        if s_env.ino == s_pwd.ino and (jruby? or s_env.dev == s_pwd.dev)
          @restart_dir = dir
          @options[:worker_directory] = dir
        end
      end

      @restart_dir ||= Dir.pwd

      @original_argv = @argv.dup

      require 'rubygems'

      # if $0 is a file in the current directory, then restart
      # it the same, otherwise add -S on there because it was
      # picked up in PATH.
      #
      if File.exist?($0)
        arg0 = [Gem.ruby, $0]
      else
        arg0 = [Gem.ruby, "-S", $0]
      end

      # Detect and reinject -Ilib from the command line
      lib = File.expand_path "lib"
      arg0[1,0] = ["-I", lib] if $:[0] == lib

      if defined? Puma::WILD_ARGS
        @restart_argv = arg0 + Puma::WILD_ARGS + @original_argv
      else
        @restart_argv = arg0 + @original_argv
      end
    end

    def close_binder_listeners
      @binder.listeners.each do |l, io|
        io.close
        uri = URI.parse(l)
        next unless uri.scheme == 'unix'
        File.unlink("#{uri.host}#{uri.path}")
      end
    end
  end
end
