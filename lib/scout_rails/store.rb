# The store encapsolutes the logic that (1) saves instrumented data by Metric name to memory and (2) maintains a stack (just an Array)
# of instrumented methods that are being called. It's accessed via +ScoutRails::Agent.instance.store+. 
class ScoutRails::Store
  attr_accessor :metric_hash
  attr_accessor :stack
  
  def initialize
    @metric_hash = Hash.new
    @stack = Array.new
  end
  
  # Stores aggregate metrics for the current transaction. When the transaction is finished, metrics
  # are merged with the +metric_hash+.
  def transaction_hash
    Thread::current[:scout_transaction_hash] || Hash.new
  end
  
  # Called when the last stack item completes for the current transaction to clear
  # for the next run.
  def reset_transaction!
    Thread::current[:scout_scope_name] = nil
    Thread::current[:scout_transaction_hash] = Hash.new
  end
  
  # Called at the start of Tracer#instrument:
  # (1) Either finds an existing MetricStats object in the metric_hash or 
  # initialize a new one. An existing MetricStats object is present if this +metric_name+ has already been instrumented.
  # (2) Adds a StackItem to the stack. This StackItem is returned and later used to validate the item popped off the stack
  # when an instrumented code block completes.
  def record(metric_name)
    item = ScoutRails::StackItem.new(metric_name)
    stack << item
    item
  end
  
  def stop_recording(sanity_check_item)
    item = stack.pop
    raise "items not equal: #{item.inspect} / #{sanity_check_item.inspect}" if item != sanity_check_item
    duration = Time.now - item.start_time
    if last=stack.last
      last.children_time += duration
    end
    meta = ScoutRails::MetricMeta.new(item.metric_name)
    stat = transaction_hash[meta] || ScoutRails::MetricStats.new
    
    stat.update!(duration,duration-item.children_time)
    transaction_hash[meta] = stat   
    
    if stack.empty?
      ScoutRails::Agent.instance.logger.debug "Transaction complete. Merging #{transaction_hash.size} metrics."
      merge_data(transaction_hash)
      reset_transaction!
    end
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