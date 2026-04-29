require 'log'

require_relative File.join(File.dirname(__FILE__), 'lib/sqlite-jdbc-3.53.0.0.jar')

# config check
bad = []
unless AppConfig.has_key?(:as_arclight_solr_url)
  bad.push("as_arclight plugin requires AppConfig[:as_arclight_solr_url] to be set. Example: http://localhost:8983/solr/blacklight-core")
end
unless AppConfig.has_key?(:as_arclight_indexing_frequency_seconds)
  bad.push("as_arclight plugin requires AppConfig[:as_arclight_indexing_frequency_seconds] to be set. Example: 60")
end
if AppConfig.has_key?(:as_arclight_ead_id_prefix)
  if AppConfig[:as_arclight_ead_id_prefix].is_a?(String)
    if AppConfig[:as_arclight_ead_id_prefix].include?(' ')
      # FIXME: other rules?
      bad.push("as_arclight plugin AppConfig[:as_arclight_ead_id_prefix] cannot contain spaces")
    end
  else
    bad.push("as_arclight plugin AppConfig[:as_arclight_ead_id_prefix] must be a String")
  end
end
if AppConfig.has_key?(:as_arclight_ref_id_prefix)
  if AppConfig[:as_arclight_ref_id_prefix].is_a?(String)
    if AppConfig[:as_arclight_ref_id_prefix].include?(' ')
      # FIXME: other rules?
      bad.push("as_arclight plugin AppConfig[:as_arclight_ref_id_prefix] cannot contain spaces")
    end
  else
    bad.push("as_arclight plugin AppConfig[:as_arclight_ref_id_prefix] must be a String")
  end
end
unless bad.empty?
  raise bad.join("\n")
end


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
