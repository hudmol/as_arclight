require 'sequel'
require 'record_inheritance'

require_relative 'mappers/arclight_mapper'
require_relative 'mappers/resource_mapper'
require_relative 'mappers/archival_object_mapper'

#require_relative '../../../../indexer/app/lib/periodic_indexer'

require 'set'

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
    @thread_count = AppConfig[:arclight_indexer_thread_count].to_i
    @records_per_thread = AppConfig[:arclight_indexer_records_per_thread].to_i

    @unpublished_records = java.util.Collections.synchronizedList(java.util.ArrayList.new)

    @db_path = File.join(AppConfig[:shared_storage], "arclight_indexer.db")
    @db = Sequel.connect("jdbc:sqlite:#{@db_path}")

    # FIXME: check these
    @db.run("PRAGMA synchronous = OFF;")
    @db.run("PRAGMA journal_mode = OFF;")
    init_schema
    Log.info('Initialized ArcLight Indexer db at: ' + @db_path)
  end

  def init_schema
    @db.create_table?(:resource) do
      primary_key :id
      String :uri
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
    [:resource, :archival_object]
  end

  def configure_doc_rules
    add_document_prepare_hook {|doc, record|
      resource_uri = if doc['primary_type'] == 'resource'
                       record['record']['uri']
                     elsif doc['primary_type'] == 'archival_object'
                       record['record']['resource']['ref']
                     end

      # remember the resource uri so we can index its entire tree later
      @db[:resource].insert(:uri => resource_uri)
    }
  end

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
#        build_fullrecord(doc, record)
      end
    }
  end

  def skip_index_record?(record)
    published = record['record']['publish']

    stage_unpublished_for_deletion("#{record['record']['uri']}#pui") unless published

    !published
  end


  def skip_index_doc?(doc)
    published = doc['publish']

    stage_unpublished_for_deletion(doc['id']) unless published

    !published
  end

  def map_children(waypoints_json, resource_uri, parent_doc_id, parent_uri)
    waypoints_json.each do |waypoint_record|
      record_uri = waypoint_record.fetch('uri')
      ao_json = JSONModel::HTTP.get_json(record_uri, 'resolve[]' => ArchivalObjectMapper.resolves)
      mapper = ArchivalObjectMapper.new(ao_json)
      ao_doc_id = @db[:document].insert(:resource_uri => resource_uri, :parent_id => parent_doc_id, :json => mapper.map.json)

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

  def index_round_complete(repository)
    batch = IndexBatch.new

    @db[:resource].select_map(:uri).uniq.each do |resource_uri|
      resource_json = JSONModel::HTTP.get_json(resource_uri, 'resolve[]' => ResourceMapper.resolves)

      if resource_json['publish']
        mapper = ResourceMapper.new(resource_json)
        resource_doc_id = @db[:document].insert(:resource_uri => resource_uri, :parent_id => nil, :json => mapper.map.json)

        # walk the tree saving mapped docs as we go
        root_json = JSONModel::HTTP.get_json(resource_uri + '/tree/root', :published_only => true)

        map_waypoints(root_json, resource_uri, resource_doc_id, nil)

        log "Generated index docs for #{resource_uri}"

      else
        # FIXME: delete
      end

    end

    if batch.length > 0
      log "Indexed #{batch.length} Resource trees in ArcLight for repository #{repository.repo_code}"

      pp batch

      # index_batch(batch, nil, :parent_id_field => 'pui_parent_id')
      # send_commit
      # update_mtimes = true
    end

    # if tree_indexer.deletes.length > 0
    #   tree_indexer.deletes.each_slice(100) do |deletes|
    #     delete_records(deletes, :parent_id_field => 'pui_parent_id')
    #   end
    # end

    # handle_deletes(:parent_id_field => 'pui_parent_id')

    # Delete any unpublished records and decendents
    # delete_records(@unpublished_records, :parent_id_field => 'pui_parent_id')
    # @unpublished_records.clear()

    # checkpoints.each do |repository, type, start|
    #   @state.set_last_mtime(repository.id, type, start, state_type) if update_mtimes
    # end

    # all done, so clear the table
    # @db[:resource].delete
  end

  def stage_unpublished_for_deletion(doc_id)
    @unpublished_records.add(doc_id) if doc_id =~ /#pui$/
  end

  def repositories_updated_action(updated_repositories)

    updated_repositories.each do |repository|

      if !repository['record']['publish']

        # Delete PUI-only Solr documents in case this is the first index run after the repository has been unpublished
        req = Net::HTTP::Post.new("#{solr_url.path}/update")
        req['Content-Type'] = 'application/json'

        # FIXME: it seems ArcLight doesn't store the repo code, just it's name
        # so this for now, but it's no good
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
