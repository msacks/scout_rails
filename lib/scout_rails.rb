module ScoutRails
end
require 'socket'
require 'set'
require 'net/http'
require File.expand_path('../scout_rails/version.rb', __FILE__)
require File.expand_path('../scout_rails/agent.rb', __FILE__)
require File.expand_path('../scout_rails/layaway.rb', __FILE__)
require File.expand_path('../scout_rails/layaway_file.rb', __FILE__)
require File.expand_path('../scout_rails/config.rb', __FILE__)
require File.expand_path('../scout_rails/environment.rb', __FILE__)
require File.expand_path('../scout_rails/metric_meta.rb', __FILE__)
require File.expand_path('../scout_rails/metric_stats.rb', __FILE__)
require File.expand_path('../scout_rails/stack_item.rb', __FILE__)
require File.expand_path('../scout_rails/store.rb', __FILE__)
require File.expand_path('../scout_rails/tracer.rb', __FILE__)
require File.expand_path('../scout_rails/instruments/process/process_cpu.rb', __FILE__)
require File.expand_path('../scout_rails/instruments/process/process_memory.rb', __FILE__)

if defined?(Rails) and Rails.respond_to?(:version) and Rails.version =~ /^3/
  module ScoutRails
    class Railtie < Rails::Railtie
      initializer "scout_rails.start" do |app|
        ScoutRails::Agent.instance.start
      end
    end
  end
else
  ScoutRails::Agent.instance.start
end

