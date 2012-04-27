module ScoutRails::Instruments
  # Contains ActiveRecord instrument, aliasing +ActiveRecord::ConnectionAdapters::AbstractAdapter#log+ calls
  # to trace calls to the database. 
  module ActiveRecordInstruments
    def self.included(instrumented_class)
      ScoutRails::Agent.instance.logger.debug "Instrumenting #{instrumented_class.inspect}"
      instrumented_class.class_eval do
        unless instrumented_class.method_defined?(:log_without_scout_instruments)
          alias_method :log_without_scout_instruments, :log
          alias_method :log, :log_with_scout_instruments
          protected :log
        end
      end
    end # self.included
    
    def log_with_scout_instruments(*args, &block)
      sql, name = args
      self.class.instrument(scout_ar_metric_name(sql,name)) do
        log_without_scout_instruments(sql, name, &block)
      end
    end
    
    # Searches for the first AR model in the call stack. If found, adds it to a Hash of 
    # classes and methods to later instrument. Used to provide a better breakdown.
    def scout_instrument_caller(called)
      model_call = called.find { |call| call =~ /\/app\/models\/(.+)\.rb:\d+:in `(.+)'/ }
      if model_call and !model_call.include?("without_scout_instrument")
       set=ScoutRails::Agent.instance.dynamic_instruments[$1.camelcase] || Set.new
       ScoutRails::Agent.instance.dynamic_instruments[$1.camelcase] = (set << $2)
      end
    end
    
    # Only instrument the caller if dynamic_instruments isn't disabled. By default, it is enabled.
    def scout_dynamic?
      dynamic=ScoutRails::Agent.instance.config.settings['dynamic_instruments']
      dynamic.nil? or dynamic
    end
    
    def scout_ar_metric_name(sql,name)
      if name && (parts = name.split " ") && parts.size == 2
        model = parts.first
        # samples 10% of calls
        if scout_dynamic? and rand*10 < 1
          scout_instrument_caller(caller(10)[0..9]) # for performance, limits the number of call stack items to examine
        end
        operation = parts.last.downcase
        metric_name = case operation
                      when 'load' then 'find'
                      when 'indexes', 'columns' then nil # not under developer control
                      when 'destroy', 'find', 'save', 'create' then operation
                      when 'update' then 'save'
                      else
                        if model == 'Join'
                          operation
                        end
                      end
        metric = "ActiveRecord/#{model}/#{metric_name}" if metric_name
        metric = "Database/SQL/other" if metric.nil?
      else
        metric = "Database/SQL/Unknown"
      end
      metric
    end
    
  end # module ActiveRecordInstruments
end # module Instruments

def add_instruments
  if defined?(ActiveRecord) && defined?(ActiveRecord::Base)
    ActiveRecord::ConnectionAdapters::AbstractAdapter.module_eval do
      include ::ScoutRails::Instruments::ActiveRecordInstruments
      include ::ScoutRails::Tracer
    end
    ActiveRecord::Base.class_eval do
       include ::ScoutRails::Tracer
    end
    ScoutRails::Agent.instance.logger.debug "Dynamic instrumention is #{ActiveRecord::Base.connection.scout_dynamic? ? 'enabled' : 'disabled'}"
  end
end

if defined?(::Rails) && ::Rails::VERSION::MAJOR.to_i == 3
  Rails.configuration.after_initialize do
    ScoutRails::Agent.instance.logger.debug "Adding ActiveRecord instrumentation to a Rails 3 app"
    add_instruments
  end
else
  add_instruments
end