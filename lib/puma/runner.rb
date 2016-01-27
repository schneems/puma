module Puma
  class Runner
    def initialize(cli)
      @cli = cli
      @options = cli.options
      @app = nil
      @control = nil
    end

    def daemon?
      @cli.daemon
    end

    def development?
      @cli.puma_environment == "development"
    end

    def log(str)
      @cli.log str
    end

    def error(str)
      @cli.error str
    end

    def before_restart
      @control.stop(true) if @control
    end

    def start_control
      str = @cli.control_url
      return unless str

      require 'puma/app/status'

      uri = URI.parse str

      app = Puma::App::Status.new @cli

      if token = @cli.control_auth_token
        app.auth_token = token unless token.empty? or token == :none
      end

      control = Puma::Server.new app, @cli.events
      control.min_threads = 0
      control.max_threads = 1

      case uri.scheme
      when "tcp"
        log "* Starting control server on #{str}"
        control.add_tcp_listener uri.host, uri.port
      when "unix"
        log "* Starting control server on #{str}"
        path = "#{uri.host}#{uri.path}"

        control.add_unix_listener path
      else
        error "Invalid control URI: #{str}"
      end

      control.run
      @control = control
    end

    def ruby_engine
      if !defined?(RUBY_ENGINE) || RUBY_ENGINE == "ruby"
        "ruby #{RUBY_VERSION}-p#{RUBY_PATCHLEVEL}"
      else
        "#{RUBY_ENGINE} #{RUBY_VERSION}"
      end
    end

    def output_header(mode)
      min_t = @cli.min_threads
      max_t = @cli.max_threads

      log "Puma starting in #{mode} mode..."
      log "* Version #{Puma::Const::PUMA_VERSION} (#{ruby_engine}), codename: #{Puma::Const::CODE_NAME}"
      log "* Min threads: #{min_t}, max threads: #{max_t}"
      log "* Environment: #{ENV['RACK_ENV']}"

      if @cli.mode == :tcp
        log "* Mode: Lopez Express (tcp)"
      end
    end

    def redirect_io
      stdout = @cli.redirect_stdout
      stderr = @cli.redirect_stderr
      append = @cli.redirect_append

      if stdout
        STDOUT.reopen stdout, (append ? "a" : "w")
        STDOUT.sync = true
        STDOUT.puts "=== puma startup: #{Time.now} ==="
      end

      if stderr
        STDERR.reopen stderr, (append ? "a" : "w")
        STDERR.sync = true
        STDERR.puts "=== puma startup: #{Time.now} ==="
      end
    end

    def load_and_bind
      unless @cli.config.app_configured?
        error "No application configured, nothing to run"
        exit 1
      end

      # Load the app before we daemonize.
      begin
        @app = @cli.config.app
      rescue Exception => e
        log "! Unable to load application: #{e.class}: #{e.message}"
        raise e
      end

      @cli.binder.parse @cli.binds, self
    end

    def app
      @app ||= @cli.config.app
    end

    def start_server
      min_t = @cli.min_threads
      max_t = @cli.max_threads

      server = Puma::Server.new app, @cli.events, @options
      server.min_threads = min_t
      server.max_threads = max_t
      server.inherit_binder @cli.binder

      if @cli.mode == :tcp
        server.tcp_mode!
      end

      unless development?
        server.leak_stack_on_error = false
      end

      server
    end
  end
end
