module ScoutRails::Instruments
  module ActionControllerInstruments
    # Instruments the action and tracks errors.
    def process_action(*args)
      scout_controller_action = "Controller/#{controller_path}/#{action_name}"
      self.class.instrument(scout_controller_action) do
        Thread::current[:scout_scope_name] = scout_controller_action
        begin
          super
        rescue Exception => e
          ScoutRails::Agent.instance.store.track!("Errors/Request",1, :scope => nil)
          raise
        ensure
          Thread::current[:scout_scope_name] = nil
        end
      end
    end
  end
end

if defined?(ActionController) && defined?(ActionController::Base)
  ScoutRails::Agent.instance.logger.debug "Instrumenting ActionController::Base"
  ActionController::Base.class_eval do
    include ScoutRails::Tracer
    include ::ScoutRails::Instruments::ActionControllerInstruments
  end
end

if defined?(ActionView) && defined?(ActionView::PartialRenderer)
  ScoutRails::Agent.instance.logger.debug "Instrumenting ActionView::PartialRenderer"
  ActionView::PartialRenderer.class_eval do
    include ScoutRails::Tracer
    instrument_method :render_partial, 'View/#{@template.virtual_path}/Rendering'
  end
end
