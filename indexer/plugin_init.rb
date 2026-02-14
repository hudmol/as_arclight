require 'log'

# FIXME: the sleep and the const test are hacky work arounds
# this file is getting loaded twice - annoying - and
# PeriodicIndexer isn't loaded when is gets called
# so we hang around for a second, and blah
sleep 1
unless Object.const_defined?('ArclightIndexer')
  Thread.new do
    begin
      require_relative '../../../indexer/app/lib/periodic_indexer'
      require_relative  'lib/arclight_indexer'

      Log.info("Starting ArcLight indexer")

      ArclightIndexer.get_indexer(state = nil, name = 'ArcLight Indexer').run
    rescue
      Log.error("Unexpected failure in ArcLight indexer: #{$!}")
    end
  end
end
