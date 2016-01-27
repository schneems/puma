module Puma
  class Launcher
    def initialize(cli_options = {})
      @cli_options = cli_options
      @runner      = nil
    end

    ## THIS STUFF IS NEEDED FOR RUNNER

    # Delegate +log+ to +@events+
    #
    def log(str)
      @events.log str
    end

    # Delegate +error+ to +@events+
    #
    def error(str)
      @events.error str
    end

    def debug(str)
      @events.log "- #{str}" if debug
    end

    def config
      @config
    end

    def stats
      @runner.stats
    end

    def halt
      @status = :halt
      @runner.halt
    end

    def binder
      @binder
    end

    def events
      @events
    end

    def write_state
      write_pid

      path = @state
      return unless path

      state = { 'pid' => Process.pid }
      cfg = @config.dup

      [
        :logger,
        :before_worker_shutdown, :before_worker_boot, :before_worker_fork,
        :after_worker_boot,
        :on_restart, :lowlevel_error_handler
      ].each { |k| cfg.options.delete(k) }
      state['config'] = cfg

      require 'yaml'
      File.open(path, 'w') { |f| f.write state.to_yaml }
    end

    def delete_pidfile
      File.unlink(pidfile) if pidfile && File.exist?(pidfile)
    end

    # If configured, write the pid of the current process out
    # to a file.
    #
    def write_pid
      path = pidfile
      return unless path

      File.open(path, 'w') { |f| f.puts Process.pid }
      cur = Process.pid
      at_exit do
        delete_pidfile if cur == Process.pid
      end
    end

    attr_reader   :options
    attr_accessor :binder, :config, :events
    ## THIS STUFF IS NEEDED FOR RUNNER

    def setup(options)
      @options = options
      parse_options

      Dir.chdir(directory) if directory

      prune_bundler if prune_bundler?

      set_rack_environment

      if clustered?
        @events.formatter = Events::PidFormatter.new
        @options[:logger] = @events

        @runner = Cluster.new(self)
      else
        @runner = Single.new(self)
      end

      @status = :run
    end



    attr_accessor :runner

    def stop
      @status = :stop
      @runner.stop
    end

    def restart
      @status = :restart
      @runner.restart
    end

    def run
      setup_signals
      set_process_title
      @runner.run

      case @status
      when :halt
        log "* Stopping immediately!"
      when :run, :stop
        graceful_stop
      when :restart
        log "* Restarting..."
        @runner.before_restart
        restart!
      when :exit
        # nothing
      end
    end


    def clustered?
      workers > 0
    end

    def jruby?
      Puma.jruby?
    end

    def windows?
      Puma.windows?
    end


    def prune_bundler
      return unless defined?(Bundler)
      puma = Bundler.rubygems.loaded_specs("puma")
      dirs = puma.require_paths.map { |x| File.join(puma.full_gem_path, x) }
      puma_lib_dir = dirs.detect { |x| File.exist? File.join(x, '../bin/puma-wild') }

      unless puma_lib_dir
        log "! Unable to prune Bundler environment, continuing"
        return
      end

      deps = puma.runtime_dependencies.map do |d|
        spec = Bundler.rubygems.loaded_specs(d.name)
        "#{d.name}:#{spec.version.to_s}"
      end

      log '* Pruning Bundler environment'
      home = ENV['GEM_HOME']
      Bundler.with_clean_env do
        ENV['GEM_HOME'] = home
        wild = File.expand_path(File.join(puma_lib_dir, "../bin/puma-wild"))
        args = [Gem.ruby, wild, '-I', dirs.join(':'), deps.join(',')] + @original_argv
        Kernel.exec(*args)
      end
    end

    def restart!
      @options[:on_restart].each do |block|
        block.call self
      end

      if jruby?
        close_binder_listeners

        require 'puma/jruby_restart'
        JRubyRestart.chdir_exec(@restart_dir, restart_args)
      elsif windows?
        close_binder_listeners

        argv = restart_args
        Dir.chdir(@restart_dir)
        argv += [redirects] if RUBY_VERSION >= '1.9'
        Kernel.exec(*argv)
      else
        redirects = {:close_others => true}
        @binder.listeners.each_with_index do |(l, io), i|
          ENV["PUMA_INHERIT_#{i}"] = "#{io.to_i}:#{l}"
          redirects[io.to_i] = io.to_i
        end

        argv = restart_args
        Dir.chdir(@restart_dir)
        argv += [redirects] if RUBY_VERSION >= '1.9'
        Kernel.exec(*argv)
      end
    end

    def jruby_daemon_start
      require 'puma/jruby_restart'
      JRubyRestart.daemon_start(@restart_dir, restart_args)
    end

    def restart_args
      cmd = restart_cmd
      if cmd
        cmd.split(' ') + @original_argv
      else
        @restart_argv
      end
    end

    attr_reader   :pidfile, :daemon, :binds, :tag, :directory,
                   :workers, :debug, :on_restart, :control_url, :control_auth_token, :min_threads,
                   :max_threads, :redirect_stdout, :redirect_stderr, :redirect_append,
                   :mode

    attr_accessor :puma_environment


  private
    def unsupported(str)
      @events.error(str)
      raise UnsupportedOption
    end

    def parse_options
      find_config

      @config = Puma::Configuration.new @cli_options

      # Advertise the Configuration
      Puma.cli_config = @config

      @config.load
      options             = @config.options
      @options            = options # option hash runs deep

      @pidfile            = options[:pidfile]
      @daemon             = options[:daemon]
      @binds              = options[:binds]
      @tag                = options[:tag]
      @puma_environment   = options[:environment]
      @preload_app        = options[:preload_app]
      @directory          = options[:directory]
      @workers            = options[:workers]
      @debug              = options[:debug]
      @on_restart         = options[:on_restart]
      @restart_cmd        = options[:restart_cmd]

      # Needed for Runner
      @control_url        = options[:control_url]
      @control_auth_token = options[:control_auth_token]
      @min_threads        = options[:min_threads]
      @max_threads        = options[:max_threads]
      @redirect_stdout    = options[:redirect_stdout]
      @redirect_stderr    = options[:redirect_stderr]
      @redirect_append    = options[:redirect_append]
      @mode               = options[:mode]

      if clustered? && (jruby? || windows?)
        unsupported 'worker mode not supported on JRuby or Windows'
      end

      if daemon && windows?
        unsupported 'daemon mode not supported on Windows'
      end
    end

    def find_config
      if @cli_options[:config_file] == '-'
        @cli_options[:config_file] = nil
      else
        @cli_options[:config_file] ||= %W(config/puma/#{env}.rb config/puma.rb).find { |f| File.exist?(f) }
      end
    end

    def graceful_stop
      @runner.stop_blocked
      log "=== puma shutdown: #{Time.now} ==="
      log "- Goodbye!"
    end

    def set_process_title
      Process.respond_to?(:setproctitle) ? Process.setproctitle(title) : $0 = title
    end

    def title
      buffer = "puma #{Puma::Const::VERSION} (#{@binds.join(',')})"
      buffer << " [#{@tag}]" if @tag && !@tag.empty?
      buffer
    end

    def set_rack_environment
      puma_environment = env
      ENV['RACK_ENV']  = env
    end

    def env
        puma_environment           ||
        @cli_options[:environment] ||
        ENV['RACK_ENV']            ||
        'development'
    end

    def prune_bundler?
      @options[:prune_bundler] && clustered? && !preload_app
    end

    def setup_signals
      begin
        Signal.trap "SIGUSR2" do
          restart
        end
      rescue Exception
        log "*** SIGUSR2 not implemented, signal based restart unavailable!"
      end

      begin
        Signal.trap "SIGUSR1" do
          phased_restart
        end
      rescue Exception
        log "*** SIGUSR1 not implemented, signal based restart unavailable!"
      end

      begin
        Signal.trap "SIGTERM" do
          stop
        end
      rescue Exception
        log "*** SIGTERM not implemented, signal based gracefully stopping unavailable!"
      end

      begin
        Signal.trap "SIGHUP" do
          redirect_io
        end
      rescue Exception
        log "*** SIGHUP not implemented, signal based logs reopening unavailable!"
      end

      if jruby?
        Signal.trap("INT") do
          @status = :exit
          graceful_stop
          exit
        end
      end
    end
  end
end