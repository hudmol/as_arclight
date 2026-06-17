require 'sequel'

require_relative 'mappers/arclight_mapper'
require_relative 'iiif_client'

class ArclightIndexer < PeriodicIndexer
  class << self
    attr_accessor :data_dir
  end

  SolrTarget = Struct.new(:url, :label, :user, :pass) do
    def parsed_url
      @parsed_url ||= URI.parse(url)
    end

    def name
      label || url
    end

    def basic_auth_enabled?
      user && pass
    end
  end

  def solr_targets
    @targets ||= AppConfig[:as_arclight_solr_targets].map do |target|
      SolrTarget.new(target[:url],
                     target[:label],
                     target[:user],
                     target[:pass])
    end
  end

  # this should never be called, so raise if it is
  def solr_url
    raise "as_arclight plugin: unexpected call to #solr_url!"
  end

  def send_commit(type = :hard)
    # we decide when to send commits!
  end

  def send_commit_to_all_targets
    solr_targets.each do |target|
      send_commit_for_target(target)
    end
  end

  def send_commit_for_target(target)
    req = request_for_target(target)
    req.body = {:commit => {"softCommit" => false }}.to_json
    resp = do_http_request(target.parsed_url, req)

    if resp.code == '200'
      Log.debug "as_arclight plugin: Sent commit to #{target.name}"
      true
    else
      if resp.body =~ /exceeded limit of maxWarmingSearchers/
        Log.warn "as_arclight plugin: Solr response when sending commit to #{target.name} -- #{resp.body}"
        true
      else
        Log.error "as_arclight plugin: Error when committing to #{target.name} -- #{resp.body}"
        false
      end
    end
  end

  # this is called from #handle_deletes which is called at the end of #run_index_round
  # so, we don't want to delete anything in here - just flag for delete
  def delete_records(records, opts = {})
    return if records.empty?

    records.each do |uri|
      if parsed_uri = JSONModel.parse_reference(uri)
        if parsed_uri[:type] == 'resource'
          flag_for_delete(uri)
        elsif parsed_uri[:type] == 'archival_object'
          # nothing to do - the resource's mtime will be bumped by the delete
          Log.debug "as_arclight plugin: ignoring deleted archival_object #{uri} - its resource will be reindexed"
        else
          # any other record type is also ignoreable
        end
      end
    end
  end

  def request_for_target(target)
    req = Net::HTTP::Post.new("#{target.parsed_url.path}/update")
    req['Content-Type'] = 'application/json'

    if target.basic_auth_enabled?
      req.basic_auth(target.user, target.pass)
    end

    req
  end

  ARCLIGHT_RESOLVES = AppConfig.has_key?(:as_arclight_resolves) ? AppConfig[:as_arclight_resolves] : []

  def initialize(backend = nil, state = nil, name)
    state_class = Object.const_get(AppConfig[:index_state_class])
    index_state = state || state_class.new("indexer_arclight_state")

    super(backend, index_state, name)

    @time_to_sleep = AppConfig[:as_arclight_indexing_frequency_seconds].to_i
    @thread_count = 1

    @db_path = File.join(ArclightIndexer.data_dir, "arclight_indexer.db")
    unless File.exist?(@db_path)
      Log.info 'as_arclight plugin: Initializing db at ' + @db_path
    end

    @db = Sequel.connect("jdbc:sqlite:#{@db_path}")

    @db.run("PRAGMA journal_mode = WAL;")
    init_schema

    @failed_index_retry_delay_seconds = AppConfig[:as_arclight_failed_index_retry_delay_seconds] rescue 60 * 60

    @failed_index_max_failures = AppConfig[:as_arclight_failed_index_max_failures] rescue 100

    if AppConfig.has_key?(:as_arclight_reset_queue_on_start) && AppConfig[:as_arclight_reset_queue_on_start]
      Log.warn 'as_arclight plugin: Resetting queue!'
      @db[:resource].delete
    end
  end

  def init_schema
    @db.create_table?(:resource) do
      primary_key :id
      String :uri, :null => false, :unique => true
    end

    @db.create_table?(:deleted_resource) do
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

    unless @db[:resource].columns.include?(:next_retry_time)
      @db.alter_table(:resource) do
        add_column :next_retry_time, :Bignum
      end
    end

    unless @db[:resource].columns.include?(:failure_count)
      @db.alter_table(:resource) do
        add_column :failure_count, :Bignum, :default => 0
      end
    end

  end

  def fetch_records(type, ids, resolve)
    JSONModel(type).all(:id_set => ids.join(","), 'resolve[]' => resolve)
  end

  def self.get_indexer(state = nil, name = "Arclight Indexer")
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
      # make sure uri is a ref to a resource
      parsed_ref = JSONModel.parse_reference(uri)
      unless parsed_ref && parsed_ref[:type] == 'resource'
        next
      end

      # Clear any existing rows prior to insert to reset our failure counts
      @db[:resource].filter(:uri => uri).delete
      @db[:resource].insert(:uri => uri)
    end
  end

  def flag_for_delete(*uris)
    uris.each do |uri|
      # make sure uri is a ref to a resource
      parsed_ref = JSONModel.parse_reference(uri)
      unless parsed_ref && parsed_ref[:type] == 'resource'
        next
      end

      begin
        @db[:deleted_resource].insert(:uri => uri)
      rescue Sequel::UniqueConstraintViolation
        # this is ok and shoudn't happen - a record can only be deleted once
      end
    end
  end

  def index_records(records, timing = IndexerTiming.new)
    # we don't index individual records
    # so all this needs to do is remember any affected resources
    records.each do |record|
      if reference = JSONModel.parse_reference(record['uri'])
        # skip records in unpublished repos - they are deleted when the repo is indexed
        if (reference[:type] == 'repository' && !record['record']['publish']) ||
            (reference[:type] != 'repository' && !record['record']['repository']['_resolved']['publish'])
          Log.debug "as_arclight plugin: Skipping record #{record['record']['uri']} because it is in an unpublished repository"
          next
        end

        if reference[:type] == 'resource'
          flag_for_indexing(record['record']['uri'])
        elsif reference[:type] == 'archival_object'
          flag_for_indexing(record['record']['resource']['ref'])
        elsif reference[:type] == 'top_container'
          flag_for_indexing(*(record['record']['collection'].map{|c| c['ref']}.select{|ref| JSONModel.parse_reference(ref)[:type] == 'resource'}))
        end
      else
        Log.error "as_arclight plugin: Indexer couldn't parse uri #{record['uri']}"
      end
    end
  end

  def configure_doc_rules
  end

  def map_children(waypoints_json, resource_uri, parent_doc_id, parent_uri)
    fetched_child_records =
      fetch_records(:archival_object,
                    waypoints_json.map{|wp| JSONModel(:archival_object).id_for(wp.fetch('uri'))},
                    Arclight::Mapper.archival_object_mapper.resolves)
        .map {|json| [json.uri, json.to_hash(:trusted)]}
        .to_h

    waypoints_json.each do |waypoint_record|
      record_uri = waypoint_record.fetch('uri')
      child_count = waypoint_record.fetch('child_count')
      ao_json = fetched_child_records.fetch(record_uri)
      ao_json['_child_count'] = child_count
      mapper = Arclight::Mapper.archival_object_mapper.new(ao_json)
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
    Log.debug "as_arclight plugin: Dumping nested doc to #{temp_file_path}"

    begin
      fh.write('[')
      stream_doc(root_id, fh)
      fh.write(']')
    ensure
      fh.close
    end

    self_test_output_dir = case self_test_mode
                           when :record_pristine
                             AppConfig[:as_arclight_test_pristine_directory]
                           when :record_candidate
                             AppConfig[:as_arclight_test_candidate_directory]
                           else
                             nil
                           end

    if self_test_output_dir
      FileUtils.mkdir_p(self_test_output_dir)
      output_basename = @db[:document].filter(:id => root_id).get(:resource_uri).gsub(/[^a-zA-Z0-9]/, '_')
      output_file = File.join(self_test_output_dir, output_basename + ".json")

      Log.debug "as_arclight plugin: Writing #{output_file} for further inspection"
      FileUtils.cp(fh.path, output_file + ".tmp")
      File.rename(output_file + ".tmp", output_file)
    end

    Log.debug "as_arclight plugin: Dump complete, sending to Solr targets ..."

    begin
      solr_targets.each do |target|
        req = request_for_target(target)
        req['Content-Length'] = File.size(temp_file_path)

        stream = File.open(temp_file_path, "rb")

        begin
          req.body_stream = stream
          resp = do_http_request(target.parsed_url, req)

          unless resp.code == '200'
            Log.error "as_arclight plugin: Error when streaming doc for #{uri} to #{target.name}: #{resp.body}"
            next
          end
        ensure
          stream.close
        end

        if resp.code == '200'
          if send_commit_for_target(target)
            log "Indexed #{uri} to #{target.name}"
          end
        else
          Log.error "as_arclight plugin: Error commiting index doc for #{uri} to #{target.name}: #{resp.body}"
        end
      end
    ensure
      File.unlink(temp_file_path)
    end
  end

  def send_delete_for_resource(resource_uri)
    delete_json = {'delete' => {'query' => "archivesspace_uri_ssi:\"#{resource_uri}\""}}.to_json
    delete_length = delete_json.length

    solr_targets.each do |target|
      req = request_for_target(target)
      req['Content-Length'] = delete_length
      req.body = delete_json
      resp = do_http_request(target.parsed_url, req)

      if resp.code != '200'
        Log.error "as_arclight plugin: Error deleting #{resource_uri} from #{target.name}: #{resp.body}"
      end
    end
  end

  def index_round_complete(repository)
    resource_count = 0
    indexed_count = 0
    deleted_count = 0
    unpublished_count = 0

    @db[:deleted_resource].select_map(:uri).each do |resource_uri|
      Log.debug "as_arclight plugin: Ensuring resource #{resource_uri} is not in the Arclight indexes because it has been deleted in ArchivesSpace"
      send_delete_for_resource(resource_uri)
      deleted_count += 1
      resource_count += 1
      @db[:resource].filter(:uri => resource_uri).delete
      @db[:deleted_resource].filter(:uri => resource_uri).delete
    end

    if deleted_count > 0
      send_commit_to_all_targets
    end

    # Clear any records that have reached our maximum number of failures
    max_failures = @failed_index_max_failures
    @db[:resource].where { failure_count > max_failures }.each do |failed_resource|
      Log.debug "as_arclight plugin: Resource #{failed_resource[:uri]} has failed to index #{failed_resource[:failure_count]} times in a row and will be skipped"
    end

    @db[:resource].where { failure_count > max_failures }.delete

    fetch_records(:resource,
                  @db[:resource]
                    .where{(next_retry_time =~ nil) | (next_retry_time <= Time.now.to_i)}
                    .select_map(:uri)
                    .map{|resource_uri| JSONModel(:resource).id_for(resource_uri)},
                  Arclight::Mapper.resource_mapper.resolves)
      .each do |resource|

      begin
        resource_uri = resource.uri
        resource_json = resource.to_hash(:trusted)

        resource_json.merge!(JSONModel::HTTP.get_json("#{resource_uri}/arclight_extras"))
        mapper = Arclight::Mapper.resource_mapper.new(resource_json)

        if resource_json['publish'] && !resource_json['suppressed']
          Log.debug "as_arclight plugin: Preparing resource #{resource_uri}"

          resource_doc_id = @db[:document].insert(:resource_uri => resource_uri, :parent_id => nil, :json => mapper.json)

          root_json = JSONModel::HTTP.get_json(resource_uri + '/tree/root', :published_only => true)

          map_waypoints(root_json, resource_uri, resource_doc_id, nil)

          Log.debug "as_arclight plugin: Generated index docs for #{resource_uri}"

          stream_nested_doc(resource_doc_id, resource_uri)

          @db[:document].filter(:resource_uri => resource_uri).delete

          indexed_count += 1
        else
          Log.debug "as_arclight plugin: Ensuring resource #{resource_uri} is not in the Arclight indexes because it is either not published or suppressed"

          unpublished_count += 1

          send_delete_for_resource(resource_uri)
          send_commit_to_all_targets
        end

        @db[:resource].filter(:uri => resource_uri).delete
        resource_count += 1
      rescue => e
        next_retry_time = Time.now.to_i + @failed_index_retry_delay_seconds

        Log.error "as_arclight plugin: Error indexing resource #{resource_uri}: #{e}"
        Log.error "as_arclight plugin: This resource has been skipped and will be retried after #{Time.at(next_retry_time)}"
        Log.exception(e)

        @db[:resource].filter(:uri => resource_uri)
          .update(:next_retry_time => next_retry_time,
                  :failure_count => Sequel.expr(:failure_count) + 1)
      end
    end

    if resource_count > 0
      log "Processed #{resource_count} resources. Indexed: #{indexed_count}, Deleted: #{deleted_count}, Unpublished: #{unpublished_count} for repository #{repository.repo_code}"
    end
  end

  def repositories_updated_action(updated_repositories)
    updated_repositories.each do |repository|

      if !repository['record']['publish']
        solr_targets.each do |target|
          req = request_for_target(target)

          delete_request = {:delete => {'query' => "repository_ssim:\"#{repository['record']['name']}\""}}
          req.body = delete_request.to_json
          response = do_http_request(target.parsed_url, req)
          if response.code == '200'
            if send_commit_for_target(target)
              log "Deleted all documents in private repository #{repository['record']['repo_code']} for #{target.name}"
            end
          else
            Log.error "as_arclight plugin: failed to delete Arclight documents in private repository #{repository['record']['repo_code']} for #{target.name}: #{response.body}"
          end
        end
      end
    end
  end

  def self_test_mode
    @self_test_mode ||= (AppConfig[:as_arclight_test_mode] rescue nil)
  end
end
