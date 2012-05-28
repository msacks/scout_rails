# Contains the methods that instrument blocks of code. 
# 
# When a code block is wrapped inside #instrument(metric_name):
# * The #instrument method pushes a StackItem onto Store#stack
# * When a code block is finished, #instrument pops the last item off the stack and verifies it's the StackItem
#   we created earlier. 
# * Once verified, the metrics for the recording session are merged into the in-memory Store#metric_hash. The current scope
#   is also set for the metric (if Thread::current[:scout_scope_name] isn't nil).
module ScoutRails::Tracer
  def self.included(klass)
    klass.extend ClassMethods
  end
  
  module ClassMethods
    # An easier reference to the agent's associated store. 
    def store
      ScoutRails::Agent.instance.store
    end
    
    def instrument(metric_name, &block)
      stack_item = store.record(metric_name)
      begin
        yield
      ensure
        store.stop_recording(stack_item)
      end
    end
    
    def instrument_method(method,metric_name = nil)
      metric_name = metric_name || default_metric_name(method)
      return if !instrumentable?(method) or instrumented?(method,metric_name)
      class_eval instrumented_method_string(method, metric_name), __FILE__, __LINE__
      
      alias_method _uninstrumented_method_name(method, metric_name), method
      alias_method method, _instrumented_method_name(method, metric_name)
    end
    
    private
    
    def instrumented_method_string(method, metric_name)
      klass = (self === Module) ? "self" : "self.class"
      "def #{_instrumented_method_name(method, metric_name)}(*args, &block)
        result = #{klass}.instrument(\"#{metric_name}\") do
          #{_uninstrumented_method_name(method, metric_name)}(*args, &block)
        end
        result
      end"
    end
    
    # The method must exist to be instrumented.
    def instrumentable?(method)
      exists = method_defined?(method) || private_method_defined?(method)
      ScoutRails::Agent.instance.logger.warn "The method [#{self.name}##{method}] does not exist and will not be instrumented" unless exists
      exists
    end
    
    # +True+ if the method is already instrumented. 
    def instrumented?(method,metric_name)
      instrumented = method_defined?(_instrumented_method_name(method, metric_name))
      ScoutRails::Agent.instance.logger.warn "The method [#{self.name}##{method}] has already been instrumented" if instrumented
      instrumented
    end
    
    def default_metric_name(method)
      "Custom/#{self.name}/#{method.to_s}"
    end
    
    # given a method and a metric, this method returns the
    # untraced alias of the method name
    def _uninstrumented_method_name(method, metric_name)
      "#{_sanitize_name(method)}_without_scout_instrument_#{_sanitize_name(metric_name)}"
    end
    
    # given a method and a metric, this method returns the traced
    # alias of the method name
    def _instrumented_method_name(method, metric_name)
      name = "#{_sanitize_name(method)}_with_scout_instrument_#{_sanitize_name(metric_name)}"
    end
    
    # Method names like +any?+ or +replace!+ contain a trailing character that would break when
    # eval'd as ? and ! aren't allowed inside method names.
    def _sanitize_name(name)
      name.to_s.tr_s('^a-zA-Z0-9', '_')
    end
  end # ClassMethods
end # module Tracer