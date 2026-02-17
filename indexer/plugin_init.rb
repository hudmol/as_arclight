require 'log'

# This file gets loaded first by common_indexer.rb (which is too early because
# PeriodicIndexer isn't loaded yet) and then again by main.rb.  Since our
# indexer depends on PeriodicIndexer, wait until it's available.
if Object.const_defined?('PeriodicIndexer')
  require_relative 'lib/arclight_indexer'

  Thread.new do
    begin
      Log.info("Starting ArcLight indexer")

      ArclightIndexer.get_indexer(state = nil, name = 'ArcLight Indexer').run
    rescue
      Log.error("Unexpected failure in ArcLight indexer: #{$!}")
    end
  end

end
