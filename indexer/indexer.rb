require 'log'

class IndexerCommon
  Log.info('as_arclight plugin indexer initializing ...')
  add_indexer_initialize_hook do |indexer|
    indexer.add_document_prepare_hook {|doc, record|
      if ['resource', 'archival_object'].include?(doc['primary_type'])
        if record['record']['publish']
          Log.info("BETTER SYNC THIS RECORD: " + record['uri'])
        else
          Log.info("BETTER DELETE THIS RECORD - NOT PUBLISHED: " + record['uri'])
        end
      end
    }
  end
end
