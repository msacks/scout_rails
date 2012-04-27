module ScoutRails::Instruments
  module ActionControllerInstruments
    def self.included(instrumented_class)
      ScoutRails::Agent.instance.logger.debug "Instrumenting #{instrumented_class.inspect}"
      instrumented_class.class_eval do
        unless instrumented_class.method_defined?(:perform_action_without_scout_instruments)
          alias_method :perform_action_without_scout_instruments, :perform_action
          alias_method :perform_action, :perform_action_with_scout_instruments
          private :perform_action
        end
      end
    end # self.included
    
    # In addition to instrumenting actions, this also sets the scope to the controller action name. The scope is later
    # applied to metrics recorded during this transaction. This lets us associate ActiveRecord calls with 
    # specific controller actions.
    def perform_action_with_scout_instruments(*args, &block)
      scout_controller_action = "Controller/#{controller_path}/#{action_name}"
      self.class.instrument(scout_controller_action) do
        Thread::current[:scout_scope_name] = scout_controller_action
        perform_action_without_scout_instruments(*args, &block)
        Thread::current[:scout_scope_name] = nil
      end
    end
  end
end

if defined?(ActionController) && defined?(ActionController::Base)
  ActionController::Base.class_eval do
    include ScoutRails::Tracer
    include ::ScoutRails::Instruments::ActionControllerInstruments

    def rescue_action_with_scout(exception)
      ScoutRails::Agent.instance.store.track!("Errors/Request",1, :scope => nil)
      rescue_action_without_scout exception
    end

    alias_method :rescue_action_without_scout, :rescue_action
    alias_method :rescue_action, :rescue_action_with_scout
    protected :rescue_action
  end
  ScoutRails::Agent.instance.logger.debug "Instrumenting ActionView::Template"
  ActionView::Template.class_eval do
    include ::ScoutRails::Tracer
    instrument_method :render, 'View/#{path[%r{^(/.*/)?(.*)$},2]}/Rendering'
  end
end
