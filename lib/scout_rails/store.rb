# The store encapsolutes the logic that (1) saves instrumented data by Metric name to memory and (2) maintains a stack (just an Array)
# of instrumented methods that are being called. It's accessed via +ScoutRails::Agent.instance.store+. 
class ScoutRails::Store
  attr_accessor :metric_hash
  attr_accessor :stack
  
  def initialize
    @metric_hash = Hash.new
    @stack = Array.new
  end
  
  # Called at the start of Tracer#instrument:
  # (1) Either finds an existing MetricStats object in the metric_hash or 
  # initialize a new one. An existing MetricStats object is present if this +metric_name+ has already been instrumented.
  # (2) Adds a StackItem to the stack. This StackItem is returned and later used to validate the item popped off the stack
  # when an instrumented code block completes.
  def record(metric_name)
    #ScoutRails::Agent.instance.logger.debug "recording #{metric_name}"
    item = ScoutRails::StackItem.new(metric_name)
    stack << item
    item
  end
  
  def stop_recording(sanity_check_item)
    item = stack.pop
    raise "items not equal: #{item.inspect} / #{sanity_check_item.inspect}" if item != sanity_check_item
    duration = Time.now - item.start_time
    if last=stack.last
      #ScoutRails::Agent.instance.logger.debug "found an element on stack [#{last.inspect}]. adding duration #{duration} to children time [#{last.children_time}]"
      last.children_time += duration
    end
    #ScoutRails::Agent.instance.logger.debug "popped #{item.inspect} off stack. duration: #{duration}s"
    if stack.empty? # this is the last item on the stack. it shouldn't have a scope.
      Thread::current[:scout_scope_name] = nil
    end
    meta = ScoutRails::MetricMeta.new(item.metric_name)
    #ScoutRails::Agent.instance.logger.debug "meta: #{meta.inspect}"
    stat = metric_hash[meta] || ScoutRails::MetricStats.new
    #ScoutRails::Agent.instance.logger.debug "found existing stat w/ky: #{meta}" if !stat.call_count.zero?
    stat.update!(duration,duration-item.children_time)
    metric_hash[meta] = stat   
    #ScoutRails::Agent.instance.logger.debug "metric hash has #{metric_hash.size} items"
  end
  
  # Finds or creates the metric w/the given name in the metric_hash, and updates the time. Primarily used to 
  # record sampled metrics. For instrumented methods, #record and #stop_recording are used.
  #
  # Options:
  # :scope => If provided, overrides the default scope. 
  # :exclusive_time => Sets the exclusive time for the method. If not provided, uses +call_time+.
  def track!(metric_name,call_time,options = {})
     meta = ScoutRails::MetricMeta.new(metric_name)
     meta.scope = options[:scope] if options.has_key?(:scope)
     stat = metric_hash[meta] || ScoutRails::MetricStats.new
     stat.update!(call_time,options[:exclusive_time] || call_time)
     metric_hash[meta] = stat
  end
  
  # Combines old and current data
  def merge_data(old_data)
    old_data.each do |old_meta,old_stats|
      if stats = metric_hash[old_meta]
        metric_hash[old_meta] = stats.combine!(old_stats)
      else
        metric_hash[old_meta] = old_stats
      end
    end
    metric_hash
  end
  
  # Merges old and current data, clears the current in-memory metric hash, and returns
  # the merged data
  def merge_data_and_clear(old_data)
    merged = merge_data(old_data)
    self.metric_hash =  {}
    merged
  end
end # class Store