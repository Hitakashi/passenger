#  Phusion Passenger - https://www.phusionpassenger.com/
#  Copyright (c) 2010-2015 Phusion Holding B.V.
#
#  "Passenger", "Phusion Passenger" and "Union Station" are registered
#  trademarks of Phusion Holding B.V.
#
#  See LICENSE file for license information.

require 'optparse'
require 'thread'
PhusionPassenger.require_passenger_lib 'constants'
PhusionPassenger.require_passenger_lib 'ruby_core_enhancements'
PhusionPassenger.require_passenger_lib 'standalone/command'
PhusionPassenger.require_passenger_lib 'standalone/config_utils'
PhusionPassenger.require_passenger_lib 'utils'
PhusionPassenger.require_passenger_lib 'utils/tmpio'
PhusionPassenger.require_passenger_lib 'platform_info/ruby'

# ## Coding notes
#
# ### Lazy library loading
#
# We lazy load as many libraries as possible not only to improve startup performance,
# but also to ensure that we don't require libraries before we've passed the dependency
# checking stage of the runtime installer.

module PhusionPassenger
  module Standalone

    class StartCommand < Command
      def run
        parse_options
        load_local_config_file
        load_env_config
        remerge_all_options
        sanity_check_options_and_set_defaults

        lookup_runtime_and_ensure_installed
        set_stdout_stderr_binmode
        exit if @options[:runtime_check_only]

        find_apps
        find_pid_and_log_file(@app_finder, @options)
        create_working_dir
        initialize_vars
        start_engine
        begin
          show_intro_message
          maybe_daemonize
          touch_temp_dir_in_background
          ########################
          monitor_app_directories_in_background if @app_finder.multi_mode?
          ########################
          watch_log_files_in_background if should_watch_logs?
          wait_until_engine_has_exited if should_wait_until_engine_has_exited?
        rescue Interrupt
          trapsafe_shutdown_and_cleanup(true)
          exit 2
        rescue SignalException => signal
          trapsafe_shutdown_and_cleanup(true)
          if signal.message == 'SIGINT' || signal.message == 'SIGTERM'
            exit 2
          else
            raise
          end
        rescue Exception
          trapsafe_shutdown_and_cleanup(true)
          raise
        else
          trapsafe_shutdown_and_cleanup(false)
        ensure
          reset_traps_intterm
        end
      end

    private
      ################# Configuration loading, option parsing and initialization ###################

      def self.create_option_parser(options)
        logical_pwd = Dir.logical_pwd

        # If you add or change an option, make sure to update the following places too:
        # - src/ruby_supportlib/phusion_passenger/standalone/start_command/builtin_engine.rb,
        #   function #build_daemon_controller_options
        # - resources/templates/config/standalone.erb
        OptionParser.new do |opts|
          defaults = CONFIG_DEFAULTS
          nl = "\n" + ' ' * 37
          opts.banner = "Usage: passenger start [DIRECTORY] [OPTIONS]\n"
          opts.separator "Starts #{PROGRAM_NAME} Standalone and serve one or more web applications."
          opts.separator ""

          opts.separator "Server options:"
          ConfigUtils.add_option_parser_options_from_config_spec(opts,
            SERVER_CONFIG_SPEC, options)

          opts.separator ""
          opts.separator "Application loading options:"
          ConfigUtils.add_option_parser_options_from_config_spec(opts,
            APPLICATION_LOADING_CONFIG_SPECS, options)

          opts.separator ""
          opts.separator "Process management options:"
          ConfigUtils.add_option_parser_options_from_config_spec(opts,
            PROCESS_MANAGEMENT_CONFIG_SPECS, options)

          opts.separator ""
          opts.separator "Request handling options:"
          ConfigUtils.add_option_parser_options_from_config_spec(opts,
            REQUEST_HANDLING_CONFIG_SPECS, options)

          opts.separator ""
          opts.separator "Union Station options:"
          ConfigUtils.add_option_parser_options_from_config_spec(opts,
            UNION_STATION_CONFIG_SPECS, options)

          opts.separator ""
          opts.separator "Nginx engine options:"
          ConfigUtils.add_option_parser_options_from_config_spec(opts,
            NGINX_ENGINE_CONFIG_SPECS, options)

          opts.separator ""
          opts.separator "Advanced options:"
          ConfigUtils.add_option_parser_options_from_config_spec(opts,
            ADVANCED_CONFIG_SPECS, options)
        end
      end

      def load_local_config_file
        @local_options = ConfigUtils.
          load_local_config_file_from_app_dir_param!(@argv)
      end

      def load_env_config
        @env_options = ConfigUtils.load_env_config!
      end

      def remerge_all_options
        @options = ConfigUtils.remerge_all_config(@global_options,
          @local_options, @env_options, @parsed_options)
        @options_without_defaults = ConfigUtils.
          remerge_all_config_without_defaults(@global_options,
            @local_options, @env_options, @parsed_options)
      end

      def sanity_check_options_and_set_defaults
        if @argv.size > 1
          PhusionPassenger.require_passenger_lib 'standalone/app_finder'
          if !AppFinder.supports_multi?
            abort "You can only specify a single application directory as argument."
          end
        end

        if (@options_without_defaults[:address] || @options_without_defaults[:port]) &&
            @options_without_defaults[:socket_file]
          abort "You cannot specify both --address/--port and --socket. Please choose either one."
        end
        if @options[:ssl] && !@options[:ssl_certificate]
          abort "You specified --ssl. Please specify --ssl-certificate as well."
        end
        if @options[:ssl] && !@options[:ssl_certificate_key]
          abort "You specified --ssl. Please specify --ssl-certificate-key as well."
        end
        if @options[:engine] != "builtin" && @options[:engine] != "nginx"
          abort "You've specified an invalid value for --engine. The only values allowed are: builtin, nginx."
        end

        if @options[:engine] == "builtin"
          # We explicitly check that some options are set and warn the user about this,
          # in case they are using the builtin engine. We don't warn about options
          # that begin with --nginx- because that should be obvious.
          check_nginx_option_used_with_builtin_engine(:ssl, "--ssl")
          check_nginx_option_used_with_builtin_engine(:ssl_certificate, "--ssl-certificate")
          check_nginx_option_used_with_builtin_engine(:ssl_certificate_key, "--ssl-certificate-key")
          check_nginx_option_used_with_builtin_engine(:ssl_port, "--ssl-port")
          check_nginx_option_used_with_builtin_engine(:static_files_dir, "--static-files-dir")
        end

        #############
      end

      def check_nginx_option_used_with_builtin_engine(option, argument)
        if @options.has_key?(option)
          STDERR.puts "*** Warning: the #{argument} option is only allowed if you use " +
            "the 'nginx' engine. You are currently using the 'builtin' engine, so " +
            "this option has been ignored. To switch to the Nginx engine, please " +
            "pass --engine=nginx."
        end
      end

      def lookup_runtime_and_ensure_installed
        @agent_exe = PhusionPassenger.find_support_binary(AGENT_EXE)
        if @options[:nginx_bin]
          @nginx_binary = @options[:nginx_bin]
          if !@nginx_binary
            abort "*** ERROR: Nginx binary #{@options[:nginx_bin]} does not exist"
          end
          if !@agent_exe
            install_runtime
            @agent_exe = PhusionPassenger.find_support_binary(AGENT_EXE)
          end
        else
          nginx_name = "nginx-#{@options[:nginx_version]}"
          @nginx_binary = PhusionPassenger.find_support_binary(nginx_name)
          if !@agent_exe || !@nginx_binary
            install_runtime
            @agent_exe = PhusionPassenger.find_support_binary(AGENT_EXE)
            @nginx_binary = PhusionPassenger.find_support_binary(nginx_name)
          end
        end
      end

      def install_runtime
        if @options[:dont_install_runtime]
          abort "*** ERROR: Refusing to install the #{PROGRAM_NAME} Standalone runtime " +
            "because --no-install-runtime is given."
        end

        args = [
          "--brief",
          "--no-force-tip",
          # Use default Utils::Download timeouts, which are short. We want short
          # timeouts so that if the primary server is down and is not responding
          # (as opposed to responding quickly with an error), then the system
          # quickly switches to a mirror.
          "--connect-timeout", "0",
          "--idle-timeout", "0"
        ]
        if @options[:auto]
          args << "--auto"
        end
        if @options[:binaries_url_root]
          args << "--url-root"
          args << @options[:binaries_url_root]
        end
        if @options[:nginx_version]
          args << "--nginx-version"
          args << @options[:nginx_version]
        end
        if @options[:nginx_tarball]
          args << "--nginx-tarball"
          args << @options[:nginx_tarball]
        end
        if @options[:dont_compile_runtime]
          args << "--no-compile"
        end
        PhusionPassenger.require_passenger_lib 'config/install_standalone_runtime_command'
        PhusionPassenger::Config::InstallStandaloneRuntimeCommand.new(args).run
        puts
        puts "--------------------------"
        puts
      end

      def set_stdout_stderr_binmode
        # We already set STDOUT and STDERR to binmode in bin/passenger, which
        # fixes https://github.com/phusion/passenger-ruby-heroku-demo/issues/11.
        # However RuntimeInstaller sets them to UTF-8, so here we set them back.
        STDOUT.binmode
        STDERR.binmode
      end


      ################## Core logic ##################

      def find_apps
        PhusionPassenger.require_passenger_lib 'standalone/app_finder'
        @app_finder = AppFinder.new(@argv, @options)
        @apps = @app_finder.scan
        if @app_finder.multi_mode? && @options[:engine] != 'nginx'
          puts "Mass deployment enabled, so forcing engine to 'nginx'."
          @options[:engine] = 'nginx'
        end
      end

      def find_pid_and_log_file(app_finder, options)
        ConfigUtils.find_pid_and_log_file(app_finder.execution_root, options)
      end

      def create_working_dir
        # We don't remove the working dir in 'passenger start'. In daemon
        # mode 'passenger start' just quits and lets background processes
        # running. A specific background process, temp-dir-toucher, is
        # responsible for cleaning up the working dir.
        @working_dir = PhusionPassenger::Utils.mktmpdir("passenger-standalone.")
        File.chmod(0755, @working_dir)
        Dir.mkdir("#{@working_dir}/logs")
        @can_remove_working_dir = true
      end

      def initialize_vars
        @console_mutex = Mutex.new
        @termination_pipe = IO.pipe
        @threads = []
        @interruptable_threads = []
      end

      def start_engine
        metaclass = class << self; self; end
        if @options[:engine] == 'nginx'
          PhusionPassenger.require_passenger_lib 'standalone/start_command/nginx_engine'
          metaclass.send(:include, PhusionPassenger::Standalone::StartCommand::NginxEngine)
        else
          PhusionPassenger.require_passenger_lib 'standalone/start_command/builtin_engine'
          metaclass.send(:include, PhusionPassenger::Standalone::StartCommand::BuiltinEngine)
        end
        start_engine_real
      end

      # Returns the URL that the server will be listening on
      # for the given app.
      def listen_url(app)
        if app[:socket_file]
          "unix:#{app[:socket_file]}"
        else
          if @options[:engine] == 'nginx' && app[:ssl] && !app[:ssl_port]
            scheme = "https"
          else
            scheme = "http"
          end
          result = "#{scheme}://"
          if app[:port] == 80
            result << app[:address]
          else
            result << compose_ip_and_port(app[:address], app[:port])
          end
          result << "/"
          result
        end
      end

      def compose_ip_and_port(ip, port)
        if ip =~ /:/
          # IPv6
          "[#{ip}]:#{port}"
        else
          "#{ip}:#{port}"
        end
      end

      def show_intro_message
        puts "=============== Phusion Passenger Standalone web server started ==============="
        puts "PID file: #{@options[:pid_file]}"
        puts "Log file: #{@options[:log_file]}"
        puts "Environment: #{@options[:environment]}"

        if @app_finder.multi_mode?
          puts
          if @apps.empty?
            puts "No web applications detected. Waiting until you create one..."
          else
            require_hosts_file_parser
            begin
              if should_check_hosts_file?
                hosts_file = PhusionPassenger::Utils::HostsFileParser.new
              end
            rescue Errno::EACCES, Errno::ENOENT
              hosts_file = nil
            end
            warnings = 0

            if listening_on_unix_domain_socket?
              puts "Serving these applications:"
            else
              puts "Serving these applications on #{@options[:address]} port #{@options[:port]}:"
            end
            puts " Host name                     Directory"
            puts "------------------------------------------------------------"
            @apps.each do |app|
              host_name = app[:server_names][0]
              if hosts_file && !hosts_file.resolves_to_localhost?(host_name)
                host_name += " [!]"
                warnings += 1
              end
              printf " %-26s    %s\n", host_name, app[:root]
            end
            if warnings > 0
              puts
              puts "[!] = This host name does not resolve to localhost. You should add it to"
              puts "      /etc/hosts if you want to access it locally"
            end
          end
        else
          puts "Accessible via: #{listen_url(@apps[0])}"
        end

        puts
        if @options[:daemonize]
          puts "Serving in the background as a daemon."
        else
          puts "You can stop #{PROGRAM_NAME} Standalone by pressing Ctrl-C."
        end
        puts "Problems? Check https://www.phusionpassenger.com/library/admin/standalone/troubleshooting/"
        puts "==============================================================================="
      end

      def maybe_daemonize
        if @options[:daemonize]
          PhusionPassenger.require_passenger_lib 'platform_info/ruby'
          if PlatformInfo.ruby_supports_fork?
            daemonize
          else
            abort "Unable to daemonize using the current Ruby interpreter " +
              "(#{PlatformInfo.ruby_command}) because it does not support forking."
          end
        end
      end

      def daemonize
        pid = fork
        if pid
          # Parent
          exit!(0)
        else
          # Child
          trap "HUP", "IGNORE"
          STDIN.reopen("/dev/null", "r")
          STDOUT.reopen(@options[:log_file], "a")
          STDERR.reopen(@options[:log_file], "a")
          STDOUT.sync = true
          STDERR.sync = true
          Process.setsid
          @threads.clear
        end
      end

      def touch_temp_dir_in_background
        result = system(@agent_exe,
          "temp-dir-toucher",
          @working_dir,
          "--cleanup",
          "--daemonize",
          "--pid-file", "#{@working_dir}/temp_dir_toucher.pid",
          "--log-file", @options[:log_file])
        if !result
          abort "Cannot start #{@agent_exe} temp-dir-toucher"
        end
        @can_remove_working_dir = false
      end

      def watch_log_file(log_file)
        if File.exist?(log_file)
          backward = 0
        else
          # tail bails out if the file doesn't exist, so wait until it exists.
          while !File.exist?(log_file)
            sleep 1
          end
          backward = 10
        end

        IO.popen("tail -f -n #{backward} \"#{log_file}\"", "rb") do |f|
          begin
            while true
              begin
                line = f.readline
                @console_mutex.synchronize do
                  STDOUT.write(line)
                  STDOUT.flush
                end
              rescue EOFError
                break
              end
            end
          ensure
            Process.kill('TERM', f.pid) rescue nil
          end
        end
      end

      def watch_log_files_in_background
        @apps.each do |app|
          thread = Utils.create_thread_and_abort_on_exception do
            watch_log_file("#{app[:root]}/log/#{@options[:environment]}.log")
          end
          @threads << thread
          @interruptable_threads << thread
        end
        thread = Utils.create_thread_and_abort_on_exception do
          watch_log_file(@options[:log_file])
        end
        @threads << thread
        @interruptable_threads << thread
      end

      def should_watch_logs?
        return !@options[:daemonize] && @options[:log_file] != "/dev/null"
      end

      def should_wait_until_engine_has_exited?
        return !@options[:daemonize] || @app_finder.multi_mode?
      end


      ################## Shut down and cleanup ##################

      def capture_traps_intterm
        return if @traps_captured
        @traps_captured = 1
        trap("INT", &method(:trapped_intterm))
        trap("TERM", &method(:trapped_intterm))
      end

      def reset_traps_intterm
        @traps_captured = nil
        trap("INT", "DEFAULT")
        trap("TERM", "DEFAULT")
      end

      def trapped_intterm(signal)
        if @traps_captured == 1
          @traps_captured += 1
          puts "Ignoring signal #{signal} during shutdown. Send it again to force exit."
        else
          exit!(1)
        end
      end

      def trapsafe_shutdown_and_cleanup(error_occurred)
        # Ignore INT and TERM once, to allow clean shutdown in e.g. Foreman
        capture_traps_intterm

        # Stop engine
        if @engine && (error_occurred || should_wait_until_engine_has_exited?)
          @console_mutex.synchronize do
            STDOUT.write("Stopping web server...")
            STDOUT.flush
            @engine.stop
            STDOUT.puts " done"
            STDOUT.flush
          end
          @engine = nil
        end

        # Stop threads
        if @threads
          if !@termination_pipe[1].closed?
            @termination_pipe[1].write("x")
            @termination_pipe[1].close
          end
          @interruptable_threads.each do |thread|
            thread.terminate
          end
          @interruptable_threads = []
          @threads.each do |thread|
            thread.join
          end
          @threads = nil
        end

        if @can_remove_working_dir
          FileUtils.remove_entry_secure(@working_dir)
          @can_remove_working_dir = false
        end
      end

      #################

      def default_group_for(username)
        user = Etc.getpwnam(username)
        group = Etc.getgrgid(user.gid)
        return group.name
      end

      def listening_on_unix_domain_socket?
        return !!@options[:socket_file]
      end

      def should_check_hosts_file?
        require_platform_info_operating_system
        return PlatformInfo.os_name == "macosx"
      end

      def require_platform_info_operating_system
        PhusionPassenger.require_passenger_lib 'platform_info/operating_system' \
          if !defined?(PhusionPassenger::PlatformInfo) || !PlatformInfo.respond_to?(:os_name)
      end

      def require_hosts_file_parser
        PhusionPassenger.require_passenger_lib 'utils/hosts_file_parser' \
          if !defined?(PhusionPassenger::Utils::HostsFileParser)
      end

      def monitor_app_directories_in_background
        @threads << Thread.new do
          Thread.current.abort_on_exception = true
          @app_finder.monitor(@termination_pipe[0]) do |apps|
            puts "*** #{Time.now}: redeploying applications ***"
            ok = true
            begin
              pid = @engine.pid
            rescue SystemCallError, IOError => e
              # Failing to read the PID file most likely means that the
              # web server's no longer running, in which case we're supposed
              # to quit anyway. Only print an error if the web server's still
              # running.
              if !wait_on_termination_pipe(3)
                @console_mutex.synchronize do
                  error "Unable to retrieve the web server's PID (#{e})."
                end
                ok = false
              end
            end
            if ok
              # Tell the temp dir toucher that we're restarting Nginx,
              # so that it should ignore the SIGTERM that the old Watchdog
              # sends it.
              begin
                temp_dir_toucher_pid = File.open("#{@working_dir}/temp_dir_toucher.pid", "r") do |f|
                  f.read.to_i
                end
                Process.kill('HUP', temp_dir_toucher_pid)
                sleep 0.01
              rescue Errno::ENOENT, Errno::EACCES, Errno::ESRCH
              end

              # Now reload the engine.
              @apps = apps
              reload_engine(pid)
              @console_mutex.synchronize do
                show_new_app_list(apps)
              end
            end
          end
        end
      end

      def show_new_app_list(apps)
        if apps.empty?
          puts "No web applications detected. Waiting until you create one..."
        else
          require_hosts_file_parser
          begin
            if should_check_hosts_file?
              hosts_file = PhusionPassenger::Utils::HostsFileParser.new
            end
          rescue Errno::EACCES, Errno::ENOENT
            hosts_file = nil
          end
          warnings = 0

          puts "Now serving these applications:"
          puts " Host name                     Directory"
          puts "------------------------------------------------------------"
          apps.each do |app|
            host_name = app[:server_names][0]
            if hosts_file && !hosts_file.resolves_to_localhost?(host_name)
              host_name += " [!]"
              warnings += 1
            end
            printf " %-26s    %s\n", host_name, app[:root]
          end
          if warnings > 0
            puts
            puts "[!] = This host name does not resolve to localhost. You should add it to"
            puts "      /etc/hosts if you want to access it locally"
          end
          puts "------------------------------------------------------------"
        end
      end
    end

  end # module Standalone
end # module PhusionPassenger
