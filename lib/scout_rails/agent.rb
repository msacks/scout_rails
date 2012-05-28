module ScoutRails
  # The agent gathers performance data from a Ruby application. One Agent instance is created per-Ruby process. 
  #
  # Each Agent object creates a worker thread (unless monitoring is disabled or we're forking). 
  # The worker thread wakes up every +Agent#period+, merges in-memory metrics w/those saved to disk, 
  # saves the merged data to disk, and sends it to the Scout server.
  class Agent
    # Headers passed up with all API requests.
    HTTP_HEADERS = { "Agent-Hostname" => Socket.gethostname }
    DEFAULT_HOST = 'scoutapp.com'
    # see self.instance
    @@instance = nil 
    
    # Accessors below are for associated classes
    attr_accessor :store
    attr_accessor :layaway
    attr_accessor :config
    attr_accessor :environment
    
    attr_accessor :logger
    attr_accessor :log_file # path to the log file
    attr_accessor :options # options passed to the agent when +#start+ is called.
    attr_accessor :metric_lookup # Hash used to lookup metric ids based on their name and scope
    
    # All access to the agent is thru this class method to ensure multiple Agent instances are not initialized per-Ruby process. 
    def self.instance(options = {})
      @@instance ||= self.new(options)
    end
    
    # Note - this doesn't start instruments or the worker thread. This is handled via +#start+ as we don't 
    # want to start the worker thread or install instrumentation if (1) disabled for this environment (2) a worker thread shouldn't
    # be started (when forking).
    def initialize(options = {})
      @started = false
      @options ||= options
      @store = ScoutRails::Store.new
      @layaway = ScoutRails::Layaway.new
      @config = ScoutRails::Config.new(options[:config_path])
      @metric_lookup = Hash.new
      @process_cpu=ScoutRails::Instruments::Process::ProcessCpu.new(1) # TODO: the argument is the number of processors
      @process_memory=ScoutRails::Instruments::Process::ProcessMemory.new
    end
    
    def environment
      @environment ||= ScoutRails::Environment.new
    end
    
    # This is called via +ScoutRails::Agent.instance.start+ when ScoutRails is required in a Ruby application.
    # It initializes the agent and starts the worker thread (if appropiate).
    def start(options = {})
      @options.merge!(options)
      init_logger
      if !config.settings['monitor'] and !@options[:force]
        logger.warn "Monitoring isn't enabled for the [#{environment.env}] environment."
        return false
      elsif !environment.app_server
        logger.warn "Couldn't find a supported app server. Not starting agent."
        return false
      elsif started?
        logger.warn "Already started agent."
        return false
      end
      @started = true
      logger.info "Starting monitoring. Framework [#{environment.framework}] App Server [#{environment.app_server}]."
      start_instruments
      if !start_worker_thread?
        logger.debug "Not starting worker thread"
        install_passenger_worker_process_event if environment.passenger?
        return
      end
      start_worker_thread
      handle_exit
      log_version_pid
    end
    
    # Placeholder: store metrics locally on exit so those in memory aren't lost. Need to decide
    # whether we'll report these immediately or just store locally and risk having stale data.
    def handle_exit
      if environment.sinatra? || environment.jruby? || environment.rubinius?
        logger.debug "Exit handler not supported"
      else
        at_exit { at_exit { logger.debug "Shutdown!" } }
      end
    end
    
    def started?
      @started
    end
    
    def gem_root
      File.expand_path(File.join("..","..",".."), __FILE__)
    end
    
    def init_logger
      @log_file = "#{log_path}/scout_rails.log"
      @logger = Logger.new(@log_file)
      @logger.level = Logger::DEBUG
      def logger.format_message(severity, timestamp, progname, msg)
        prefix = "[#{timestamp.strftime("%m/%d/%y %H:%M:%S %z")} #{Socket.gethostname} (#{$$})] #{severity} : #{msg}\n"
      end
      @logger
    end
    
    # The worker thread will automatically start UNLESS:
    # * A supported application server isn't detected (example: running via Rails console)
    # * A supported application server is detected, but it forks (Passenger). In this case, 
    #   the agent is started in the forked process.
    def start_worker_thread?
      !environment.forking? or environment.thin?
    end
    
    def install_passenger_worker_process_event
      PhusionPassenger.on_event(:starting_worker_process) do |forked|
        logger.debug "Passenger is starting a worker process. Starting worker thread."
        self.class.instance.start_worker_thread
      end
    end
    
    def log_version_pid
      logger.info "Scout Agent [#{ScoutRails::VERSION}] Initialized"
    end
    
    def log_path
      "#{environment.root}/log"
    end
    
    # in seconds, time between when the worker thread wakes up and runs.
    def period
      60
    end
    
    # Creates the worker thread. The worker thread is a loop that runs continuously. It sleeps for +Agent#period+ and when it wakes,
    # processes data, either saving it to disk or reporting to Scout.
    def start_worker_thread(connection_options = {})
      logger.debug "Creating worker thread."
      @worker_thread = Thread.new do
        begin
          logger.debug "Starting worker thread, running every #{period} seconds"
          next_time = Time.now + period
          while true do
            now = Time.now
            while now < next_time
              sleep_time = next_time - now
              sleep(sleep_time) if sleep_time > 0
              now = Time.now
            end
            process_metrics
            while next_time <= now
              next_time += period
            end
          end
        rescue
          logger.debug "Worker Thread Exception!!!!!!!"
          logger.debug $!.message
          logger.debug $!.backtrace
        end
      end # thread new
      logger.debug "Done creating worker thread."
    end
    
    # Writes each payload to a file for auditing.
    def write_to_file(object)
      logger.debug "Writing to file"
      full_path = Pathname.new(RAILS_ROOT+'/log/audit/scout')
      ( full_path +
        "#{Time.now.strftime('%Y-%m-%d_%H:%M:%S')}.json" ).open("w") do |f|
        f.puts object.to_json
      end
    end
    
    # Before reporting, lookup metric_id for each MetricMeta. This speeds up 
    # reporting on the server-side.
    def add_metric_ids(metrics)
      metrics.each do |meta,stats|
        if metric_id = metric_lookup[meta]
          meta.metric_id = metric_id
        end
      end
    end
    
    # Called from #process_metrics, which is run via the worker thread. 
    def run_samplers
      begin
        cpu_util=@process_cpu.run # returns a hash
        logger.debug "Process CPU: #{cpu_util.inspect}"
        store.track!("CPU/Utilization",cpu_util) if cpu_util
      rescue => e
        logger.info "Error reading ProcessCpu"
        logger.debug e.message
        logger.debug e.backtrace.join("\n")
      end

      begin
        mem_usage=@process_memory.run # returns a single number, in MB
        logger.debug "Process Memory: #{mem_usage}MB"
        store.track!("Memory/Physical",mem_usage) if mem_usage
      rescue => e
        logger.info "Error reading ProcessMemory"
        logger.debug e.message
        logger.debug e.backtrace.join("\n")
      end
    end
    
    # Called in the worker thread. Merges in-memory metrics w/those on disk and reports metrics
    # to the server.
    def process_metrics
      logger.debug "Processing metrics"
      run_samplers
      metrics = layaway.deposit_and_deliver
      if metrics.any?
        add_metric_ids(metrics)  
        # for debugging, count the total number of requests    
        controller_count = 0
        metrics.each do |meta,stats|
          if meta.metric_name =~ /\AController/
            controller_count += stats.call_count
          end
        end        
        logger.debug "#{config.settings['name']} Delivering metrics for #{controller_count} requests."
        response =  post( checkin_uri,
                           Marshal.dump(metrics),
                           "Content-Type"     => "application/json" )
        if response and response.is_a?(Net::HTTPSuccess)
          directives = Marshal.load(response.body)
          self.metric_lookup.merge!(directives[:metric_lookup])
          logger.debug "Metric Cache Size: #{metric_lookup.size}"
        end
      end
    rescue
      logger.info "Error on checkin to #{checkin_uri.to_s}"
      logger.info $!.message
      logger.debug $!.backtrace
    end
    
    def checkin_uri
      URI.parse("http://#{config.settings['host'] || DEFAULT_HOST}/app/#{config.settings['key']}/checkin.scout?name=#{CGI.escape(config.settings['name'])}")
    end
    
    def post(url, body, headers = Hash.new)
      response = nil
      request(url) do |connection|
        post = Net::HTTP::Post.new( url.path +
                                    (url.query ? ('?' + url.query) : ''),
                                    HTTP_HEADERS.merge(headers) )
        post.body = body
        response=connection.request(post)
      end
      response
    end
    
    def request(url, &connector)
      response           = nil
      http               = Net::HTTP.new(url.host, url.port)
      response           = http.start(&connector)
      logger.debug "got response: #{response.inspect}"
      case response
      when Net::HTTPSuccess, Net::HTTPNotModified
        logger.debug "/checkin OK"
      when Net::HTTPBadRequest
        logger.warn "/checkin FAILED: The Account Key [#{config.settings['key']}] is invalid."
      else
        logger.debug "/checkin FAILED: #{response.inspect}"
      end
    rescue Exception
      logger.debug "Exception sending request to server: #{$!.message}"
    ensure
      response
    end
    
    # Loads the instrumention logic.
    def load_instruments
      case environment.framework
      when :rails
        require File.expand_path(File.join(File.dirname(__FILE__),'instruments/rails/action_controller_instruments.rb'))
      when :rails3
        require File.expand_path(File.join(File.dirname(__FILE__),'instruments/rails3/action_controller_instruments.rb'))
      when :sinatra
        require File.expand_path(File.join(File.dirname(__FILE__),'instruments/sinatra_instruments.rb'))
      end
      require File.expand_path(File.join(File.dirname(__FILE__),'instruments/active_record_instruments.rb'))
    rescue
      logger.warn "Exception loading instruments:"
      logger.warn $!.message
      logger.warn $!.backtrace
    end
    
    # Injects instruments into the Ruby application.
    def start_instruments
      logger.debug "Installing instrumentation"
      load_instruments
    end
    
  end # class Agent
end # module ScoutRails