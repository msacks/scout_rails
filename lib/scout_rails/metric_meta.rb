# Contains the meta information associated with a metric. Used to lookup Metrics in to Store's metric_hash.
class ScoutRails::MetricMeta
  def initialize(metric_name)
    @metric_name = metric_name
    @metric_id = nil
    @scope = Thread::current[:scout_scope_name]
  end
  attr_accessor :metric_id, :metric_name
  attr_accessor :scope
  attr_accessor :client_id
  
  # To avoid conflicts with different JSON libaries
  def to_json(*a)
     %Q[{"metric_id":#{metric_id || 'null'},"metric_name":#{metric_name.to_json},"scope":#{scope.to_json || 'null'}}]
  end
  
  def ==(o)
    self.eql?(o)
  end
  
  def hash
     h = metric_name.hash
     h ^= scope.hash unless scope.nil?
     h
   end
   
   def <=>(o)
     namecmp = self.name <=> o.name
     return namecmp if namecmp != 0
     return (self.scope || '') <=> (o.scope || '')
   end

  def eql?(o)
   self.class == o.class && metric_name.eql?(o.metric_name) && scope == o.scope && client_id == o.client_id
  end
end # class MetricMeta