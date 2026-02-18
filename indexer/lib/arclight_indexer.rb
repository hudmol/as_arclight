require 'sequel'
require 'record_inheritance'

require_relative 'mappers/arclight_mapper'
require_relative 'mappers/resource_mapper'
require_relative 'mappers/archival_object_mapper'

require_relative '../../../../indexer/app/lib/periodic_indexer'

class ArclightIndexer < PeriodicIndexer

  def solr_url
    URI.parse(AppConfig[:arclight_solr_url])
  end

  ARCLIGHT_RESOLVES = AppConfig[:record_inheritance_resolves]

  def initialize(backend = nil, state = nil, name)
    # this is a rails method apparently, and we don't have it, so yeah
    # state_class = AppConfig[:index_state_class].constantize
    state_class = Object.const_get(AppConfig[:index_state_class])
    index_state = state || state_class.new("indexer_arclight_state")

    super(backend, index_state, name)

    # Set up our JSON schemas now that we know the JSONModels have been loaded
    RecordInheritance.prepare_schemas

    @time_to_sleep = AppConfig[:arclight_indexing_frequency_seconds].to_i
    @thread_count = 1

    @db_path = File.join(AppConfig[:shared_storage], "arclight_indexer.db")
    @db = Sequel.connect("jdbc:sqlite:#{@db_path}")

    @db.run("PRAGMA journal_mode = WAL;")
    init_schema
    Log.info('Initialized ArcLight Indexer db at: ' + @db_path)
  end

  def init_schema
    @db.create_table?(:resource) do
      primary_key :id
      String :uri, :null => false, :unique => true
    end

    # start with a fresh document table
    @db.drop_table?(:document)

    @db.create_table(:document) do
      primary_key :id
      String :resource_uri
      Integer :parent_id
      blob :json
    end
  end

  def fetch_records(type, ids, resolve)
    records = JSONModel(type).all(:id_set => ids.join(","), 'resolve[]' => resolve)
    if RecordInheritance.has_type?(type)
      RecordInheritance.merge(records, :direct_only => true)
    else
      records
    end
  end

  def self.get_indexer(state = nil, name = "ArcLight Indexer")
    indexer = self.new(state, name)
  end

  def resolved_attributes
    super + ARCLIGHT_RESOLVES
  end

  def record_types
    [:resource, :archival_object, :top_container]
  end

  def flag_for_indexing(*uris)
    uris.each do |uri|
      begin
        @db[:resource].insert(:uri => uri)
      rescue Sequel::UniqueConstraintViolation
        # this is ok - just means some other record implicated
        # in the resource has already flagged it
      end
    end
  end

  def index_records(records, timing = IndexerTiming.new)
    # we don't index individual records
    # so all this needs to do is remember any affected resources
    records.each do |record|
      if reference = JSONModel.parse_reference(record['uri'])
        if reference[:type] == 'resource'
          flag_for_indexing(record['record']['uri'])
        elsif reference[:type] == 'archival_object'
          flag_for_indexing(record['record']['resource']['ref'])
        elsif reference[:type] == 'top_container'
          flag_for_indexing(record['record']['collection'].map{|c| c['ref']})
        end
      else
        Log.error "ArcLight Indexer couldn't parse uri: #{record['uri']}"
      end
    end
  end

  def configure_doc_rules
  end

  # FIXME: this is straight from the pui indexer. it might be right, but needs a check
  # Run the final doc rules after all the hooks have been added
  # This allows plugins to access ancestor data in PUI records before it is removed
  def final_doc_rules
    # this runs after the hooks in indexer_common, so we can overwrite with confidence
    add_document_prepare_hook {|doc, record|
      if RecordInheritance.has_type?(doc['primary_type'])
        # special handling for json because we need to include indirectly inherited
        # fields too - the json sent to indexer_common only has directly inherited
        # fields because only they should be indexed.
        # so we remerge without the :direct_only flag, and we remove the ancestors
        doc['json'] = ASUtils.to_json(RecordInheritance.merge(record['record'],
                                                              :remove_ancestors => true))

        # special handling for title because it is populated from display_string
        # in indexer_common and display_string is not changed in the merge process
        doc['title'] = record['record']['title'] if record['record']['title']

        # special handling for fullrecord because we don't want the ancestors indexed.
        # we're now done with the ancestors, so we can just delete them from the record
        record['record'].delete('ancestors')
        # we don't want container_profile or top_container notes indexed for the public either
        if record['record']['instances']
          record['record']['instances'].each do |instance|
            if instance['sub_container'] && instance['sub_container']['top_container']
              top_container = instance['sub_container']['top_container']
              if top_container['_resolved']
                top_container['_resolved'].delete('internal_note')
                if top_container['_resolved']['container_profile'] && top_container['_resolved']['container_profile']['_resolved']
                  top_container['_resolved']['container_profile']['_resolved'].delete('notes')
                end
              end
            end
          end
        end
      end
    }
  end

  def map_children(waypoints_json, resource_uri, parent_doc_id, parent_uri)
    waypoints_json.each do |waypoint_record|
      record_uri = waypoint_record.fetch('uri')
      child_count = waypoint_record.fetch('child_count')
      ao_json = JSONModel::HTTP.get_json(record_uri, 'resolve[]' => ArchivalObjectMapper.resolves)
      ao_json['_child_count'] = child_count
      mapper = ArchivalObjectMapper.new(ao_json)
      ao_doc_id = @db[:document].insert(:resource_uri => resource_uri, :parent_id => parent_doc_id, :json => mapper.json)

      if waypoint_record.fetch('child_count') > 0
        child_wp_json = JSONModel::HTTP.get_json(resource_uri + '/tree/node',
                                                 :node_uri => record_uri,
                                                 :published_only => true)

        # We might bomb out if a record was deleted out from under us.
        next if child_wp_json.nil?

        map_waypoints(child_wp_json, resource_uri, ao_doc_id, record_uri)
      end
    end
  end

  def map_waypoints(json, resource_uri, parent_doc_id, parent_uri)
    json.fetch('waypoints').times do |waypoint_number|
      waypoints_json = JSONModel::HTTP.get_json(resource_uri + '/tree/waypoint',
                                                :offset => waypoint_number,
                                                :parent_node => parent_uri,
                                                :published_only => true)

      map_children(waypoints_json, resource_uri, parent_doc_id, parent_uri)
    end
  end

  def stream_doc(id, fh)
    doc = @db[:document].filter(:id => id).select_map(:json).first
    kid_ids = @db[:document].filter(:parent_id => id).select_map(:id)

    if kid_ids.empty?
      fh.write(doc)
    else
      fh.write(doc[0..-2])
      fh.write(',"components":[')
      first = true
      kid_ids.each do |kid|
        if first
          first = false
        else
          fh.write(',')
        end
        stream_doc(kid, fh)
      end
      fh.write(']}')
    end
  end

  def stream_nested_doc(root_id, uri)
    # write the payload to a temp file because body_stream wants an IO
    # and this avoids having to load the whole thing into memory
    fh = Tempfile.new('arclight_stream.json')
    temp_file_path = fh.path
    log "Dumping nested doc to: #{temp_file_path}"

    begin
      fh.write('[')
      stream_doc(root_id, fh)
      fh.write(']')
    ensure
      fh.close
    end

    log "Dump complete"

    req = Net::HTTP::Post.new("#{solr_url.path}/update")
    req['Content-Type'] = 'application/json'
    req['Content-Length'] = File.size(temp_file_path)

    stream = File.open(temp_file_path, "rb")

    begin
      req.body_stream = stream
      resp = do_http_request(solr_url, req)
    ensure
      stream.close
      File.unlink(temp_file_path)
    end

    if resp.code == '200'
      send_commit
      log "Indexed #{uri}"
    else
      Log.error "ArcLight Indexer: error when indexing #{uri}: #{response.body}"
    end

  end

  def index_round_complete(repository)
    resource_count = 0
    indexed_count = 0
    deleted_count = 0
    @db[:resource].select_map(:uri).each do |resource_uri|
      resource_json = JSONModel::HTTP.get_json(resource_uri, 'resolve[]' => ResourceMapper.resolves)
      resource_json.merge!(JSONModel::HTTP.get_json("#{resource_uri}/arclight_extras"))

      if resource_json['publish']
        log "Preparing resource: #{resource_uri}"

        mapper = ResourceMapper.new(resource_json)
        resource_doc_id = @db[:document].insert(:resource_uri => resource_uri, :parent_id => nil, :json => mapper.json)

        root_json = JSONModel::HTTP.get_json(resource_uri + '/tree/root', :published_only => true)

        map_waypoints(root_json, resource_uri, resource_doc_id, nil)

        log "Generated index docs for #{resource_uri}"

        stream_nested_doc(resource_doc_id, resource_uri)

        @db[:document].filter(:resource_uri => resource_uri).delete

        indexed_count += 1
      else
        log "Ensuring resource #{resource_uri} is not in the ArcLight index because it is not published"
        # FIXME: actually delete it

        deleted_count += 1
      end

      @db[:resource].filter(:uri => resource_uri).delete
      resource_count += 1
    end

    if resource_count > 0
      log "Processed #{resource_count} resources. Indexed: #{indexed_count}, Deleted: #{deleted_count} for repository #{repository.repo_code}"
    end
  end

  def repositories_updated_action(updated_repositories)
    updated_repositories.each do |repository|

      if !repository['record']['publish']

        # Delete PUI-only Solr documents in case this is the first index run after the repository has been unpublished
        req = Net::HTTP::Post.new("#{solr_url.path}/update")
        req['Content-Type'] = 'application/json'

        delete_request = {:delete => {'query' => "repository_ssim:\"#{repository['name']}\""}}
        req.body = delete_request.to_json
        response = do_http_request(solr_url, req)
        if response.code == '200'
          Log.info "ArcLight Indexer deleted all documents in private repository #{repository['record']['repo_code']}: #{response}"
        else
          Log.error "SolrIndexerError when deleting ArcLight documents in private repository #{repository['record']['repo_code']}: #{response.body}"
        end
      end
    end
  end
end
