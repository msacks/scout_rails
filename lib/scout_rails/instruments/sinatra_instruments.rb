module ScoutRails::Instruments
  module SinatraInstruments
    def route_eval_with_scout_instruments(&blockarg)
      path = unescape(@request.path_info)
      name = path
      # Go through each route and look for a match
      if routes = self.class.routes[@request.request_method]
        routes.detect do |pattern, keys, conditions, block|
          if blockarg.equal? block
            name = pattern.source
          end
        end
      end
      name.gsub!(%r{^[/^]*(.*?)[/\$\?]*$}, '\1')
      name = 'root' if name.empty?
      name = @request.request_method + ' ' + name if @request && @request.respond_to?(:request_method)      
      scout_controller_action = "Controller/Sinatra/#{name}"
      self.class.instrument(scout_controller_action) do
        Thread::current[:scout_scope_name] = scout_controller_action  
        route_eval_without_scout_instruments(&blockarg)    
      end
    end # route_eval_with_scout_instrumentss
  end # SinatraInstruments
end # ScoutRails::Instruments

if defined?(::Sinatra) && defined?(::Sinatra::Base)
  ScoutRails::Agent.instance.logger.debug "Instrumenting Sinatra"
  ::Sinatra::Base.class_eval do
    include ScoutRails::Tracer
    include ::ScoutRails::Instruments::SinatraInstruments
    alias route_eval_without_scout_instruments route_eval
    alias route_eval route_eval_with_scout_instruments
  end
end