require 'log'
require_relative 'lib/arclog'
require_relative 'lib/ead_helper'
require_relative File.join(File.dirname(__FILE__), 'lib/sqlite-jdbc-3.53.0.0.jar')

# This file gets loaded first by common_indexer.rb (which is too early because
# PeriodicIndexer isn't loaded yet) and then again by main.rb.  Since our
# indexer depends on PeriodicIndexer, wait until it's available.
if Object.const_defined?('PeriodicIndexer')
  require_relative 'lib/arclight_indexer'

  indexer = ArclightIndexer.get_indexer(state = nil, name = 'Arclight Indexer')

  Thread.new do
    begin
      ARCLog.info("Starting Arclight indexer")
      indexer.run
    rescue
      ARCLog.error("Unexpected failure in Arclight indexer: #{$!}")
      ARCLog.exception($!)
    end
  end

end
