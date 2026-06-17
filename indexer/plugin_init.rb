require 'log'
require_relative 'lib/arclog'

require_relative File.join(File.dirname(__FILE__), 'lib/sqlite-jdbc-3.53.0.0.jar')

# config check
bad = []

if AppConfig.has_key?(:as_arclight_solr_targets)
  if AppConfig[:as_arclight_solr_targets].is_a?(Array)
    AppConfig[:as_arclight_solr_targets].each_with_index do |target, ix|
      unless target.has_key?(:url)
        bad.push("as_arclight plugin requires each target definition to include a url. Target #{ix + 1} lacks one.")
      end
    end
  else
    bad.push("as_arclight plugin requires AppConfig[:as_arclight_solr_targets] to be an array of hashes containing target configurations")
  end
else
  bad.push("as_arclight plugin requires AppConfig[:as_arclight_solr_targets] to be set. Minimal example: [{:url => 'http://localhost:8983/solr/blacklight-core'}]")
end

unless AppConfig.has_key?(:as_arclight_indexing_frequency_seconds)
  bad.push("as_arclight plugin requires AppConfig[:as_arclight_indexing_frequency_seconds] to be set. Example: 60")
end

if AppConfig.has_key?(:as_arclight_resource_id_prefix)
  if AppConfig[:as_arclight_resource_id_prefix].is_a?(String)
    if AppConfig[:as_arclight_resource_id_prefix].include?(' ')
      # FIXME: other rules?
      bad.push("as_arclight plugin AppConfig[:as_arclight_resource_id_prefix] cannot contain spaces")
    end
  else
    bad.push("as_arclight plugin AppConfig[:as_arclight_resource_id_prefix] must be a String")
  end
end

if AppConfig.has_key?(:as_arclight_archival_object_id_prefix)
  if AppConfig[:as_arclight_archival_object_id_prefix].is_a?(String)
    if AppConfig[:as_arclight_archival_object_id_prefix].include?(' ')
      # FIXME: other rules?
      bad.push("as_arclight plugin AppConfig[:as_arclight_archival_object_id_prefix] cannot contain spaces")
    end
  else
    bad.push("as_arclight plugin AppConfig[:as_arclight_archival_object_id_prefix] must be a String")
  end
end

begin
  data_dir = File.join(AppConfig[:data_directory], 'as_arclight')
  Dir.mkdir(data_dir)
  ARCLog.info "Created data directory at #{data_dir}"
rescue Errno::EEXIST => e
  # good!
rescue => e
  bad.push("as_arclight plugin unable to create data directory #{data_dir}: #{e}")
end

unless bad.empty?
  raise bad.join("\n")
end


# This file gets loaded first by common_indexer.rb (which is too early because
# PeriodicIndexer isn't loaded yet) and then again by main.rb.  Since our
# indexer depends on PeriodicIndexer, wait until it's available.
if Object.const_defined?('PeriodicIndexer')
  require_relative 'lib/arclight_indexer'

  ArclightIndexer.data_dir = data_dir
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
