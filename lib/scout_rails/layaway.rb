# Stores metrics in a file before sending them to the server. Two uses:
# 1. A centralized store for multiple Agent processes. This way, only 1 checkin is sent to Scout rather than 1 per-process.
# 2. Bundling up reports from multiple timeslices to make updates more efficent server-side.
# 
# Metrics are stored in a Hash, where the keys are Time.to_i on the minute. When depositing data, 
# metrics are either merged with an existing time or placed in a new key.
class ScoutRails::Layaway
  attr_accessor :file
  def initialize
    @file = ScoutRails::LayawayFile.new
  end
  
  def deposit_and_deliver
    new_data = ScoutRails::Agent.instance.store.metric_hash
    controller_count = 0
    new_data.each do |meta,stats|
      if meta.metric_name =~ /\AController/
        controller_count += stats.call_count
      end
    end
    ScoutRails::Agent.instance.logger.debug "Depositing #{controller_count} requests into #{Time.at(slot).strftime("%m/%d/%y %H:%M:%S %z")} slot."
    
    to_deliver = {}
    file.read_and_write do |old_data|
      old_data ||= Hash.new
      # merge data
      # if the previous minute has ended, its time to send those metrics
      if old_data.any? and old_data[slot].nil?
        to_deliver = old_data
        old_data = Hash.new
      elsif old_data.any?
        ScoutRails::Agent.instance.logger.debug "Not yet time to deliver metrics for slot [#{Time.at(old_data.keys.sort.last).strftime("%m/%d/%y %H:%M:%S %z")}]"
      else
        ScoutRails::Agent.instance.logger.debug "There is no data in the layaway file to deliver."
      end
      old_data[slot]=ScoutRails::Agent.instance.store.merge_data_and_clear(old_data[slot] || Hash.new)
      ScoutRails::Agent.instance.logger.debug "Saving the following #{old_data.size} time slots locally:"
      old_data.each do |k,v|
        controller_count = 0
        new_data.each do |meta,stats|
          if meta.metric_name =~ /\AController/
            controller_count += stats.call_count
          end
        end
        ScoutRails::Agent.instance.logger.debug "#{Time.at(k).strftime("%m/%d/%y %H:%M:%S %z")} => #{controller_count} requests"
      end
      old_data
    end
    to_deliver.any? ? validate_data(to_deliver) : {}
  end
  
  # Ensures the data we're sending to the server isn't stale. 
  # This can occur if the agent is collecting data, and app server goes down w/data in the local storage. 
  # When it is restarted later data will remain in local storage but it won't be for the current reporting interval.
  # 
  # If the data is stale, an empty Hash is returned. Otherwise, the data from the most recent slot is returned.
  def validate_data(data)
    data = data.to_a.sort
    now = Time.now
    if (most_recent = data.first.first) < now.to_i - 2*60
      ScoutRails::Agent.instance.logger.debug "Local Storage is stale (#{Time.at(most_recent).strftime("%m/%d/%y %H:%M:%S %z")}). Not sending data."
      {}
    else
      data.first.last
    end
  rescue
    ScoutRails::Agent.instance.logger.debug $!.message
    ScoutRails::Agent.instance.logger.debug $!.backtrace
  end
  
  def slot
    t = Time.now
    t -= t.sec
    t.to_i
  end
end