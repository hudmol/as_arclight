require_relative 'mappers/arclight_mapper'
require_relative 'iiif_client'
require_relative 'index_version'

class ArclightIndexer < PeriodicIndexer
  ONE_INSTANCE_ONLY = java.util.concurrent.atomic.AtomicBoolean.new(false)

  class << self
    attr_accessor :data_dir
  end

  def run
    unless ONE_INSTANCE_ONLY.compareAndSet(false, true)
      raise "Already running an instance of the ARCLight Indexer!  Bailing out."
    end

    super
  end

  SolrTarget = Struct.new(:url, :label, :user, :pass) do
    def parsed_url
      @parsed_url ||= URI.parse(url)
    end

    def name
      label || url
    end

    def basic_auth_enabled?
      !!(user && pass)
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

  def log(line)
    line.gsub!(/Indexed ([0-9])/, 'Scanned \1')
    line.gsub!(/Running index round/, "Scanning for updated collections")

    ARCLog.info(line)
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
      ARCLog.debug "Sent commit to #{target.name}"
      true
    else
      if resp.body =~ /exceeded limit of maxWarmingSearchers/
        ARCLog.warn "Solr response when sending commit to #{target.name} -- #{resp.body}"
        true
      else
        ARCLog.error "Error when committing to #{target.name} -- #{resp.body}"
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
          ARCLog.debug "ignoring deleted archival_object #{uri} - its resource will be reindexed"
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

  class ConfigurationError < StandardError; end

  def check_config_or_die!
    bad = []

    if AppConfig.has_key?(:as_arclight_index_version)
      unless AppConfig[:as_arclight_index_version].is_a?(Integer)
        bad.push("as_arclight plugin requires AppConfig[:as_arclight_index_version] to be an Integer")
      end
    end

    if AppConfig.has_key?(:as_arclight_solr_targets)
      if AppConfig[:as_arclight_solr_targets].is_a?(Array)
        AppConfig[:as_arclight_solr_targets].each_with_index do |target, ix|
          unless target.has_key?(:url)
            bad.push("Each Solr target definition must include a url. Target #{ix + 1} lacks one.")
          end
        end
      else
        bad.push("AppConfig[:as_arclight_solr_targets] must be an array of hashes containing target configurations")
      end
    else
      bad.push("AppConfig[:as_arclight_solr_targets] must be set. Minimal example: [{:url => 'http://localhost:8983/solr/blacklight-core'}]")
    end

    if AppConfig.has_key?(:as_arclight_indexing_frequency_seconds)
      unless AppConfig[:as_arclight_indexing_frequency_seconds].is_a?(Integer)
        bad.push("AppConfig[:as_arclight_indexing_frequency_seconds] must be an Integer")
      end
    else
      bad.push("AppConfig[:as_arclight_indexing_frequency_seconds] is required")
    end

    if AppConfig.has_key?(:as_arclight_resource_id_prefix)
      if AppConfig[:as_arclight_resource_id_prefix].is_a?(String)
        unless AppConfig[:as_arclight_resource_id_prefix].match(/^[a-zA-Z0-9_-]*$/)
          bad.push("AppConfig[:as_arclight_resource_id_prefix] can only contain alphanumerics, dash and underscore")
        end
      else
        bad.push("AppConfig[:as_arclight_resource_id_prefix] must be a String")
      end
    end

    if AppConfig.has_key?(:as_arclight_archival_object_id_delimiter)
      if AppConfig[:as_arclight_archival_object_id_delimiter].is_a?(String)
        unless AppConfig[:as_arclight_archival_object_id_delimiter].match(/^[a-zA-Z0-9_-]*$/)
          bad.push("AppConfig[:as_arclight_archival_object_id_delimiter] can only contain alphanumerics, dash and underscore")
        end
      else
        bad.push("AppConfig[:as_arclight_archival_object_id_delimiter] must be a String")
      end
    end

    if AppConfig.has_key?(:as_arclight_iiif_manifest_uri_matcher)
      unless AppConfig[:as_arclight_iiif_manifest_uri_matcher].is_a?(Regexp)
        bad.push("AppConfig[:as_arclight_iiif_manifest_uri_matcher] must be a Regexp. The default is %r{(?=(https?://.*manifest.json))}i")
      end
    end

    if bad.empty?
      ARCLog.debug "Configuration is valid"
    else
      ARCLog.error "Configuration errors detected!\n" +
        ("*" * 100) + "\n    " +
        bad.join("\n    ") + "\n" +
        ("*" * 100) + "\n"
      raise ConfigurationError.new("as_arclight configuration error")
    end
  end

  def self.ensure_data_dir_or_die!
    begin
      data_dir = File.join(AppConfig[:data_directory], 'as_arclight')
      Dir.mkdir(data_dir)
      ARCLog.info "Created data directory at #{data_dir}"
    rescue Errno::EEXIST => e
      ARCLog.info "Using existing data directory at #{data_dir}"
    rescue => e
      ARCLog.error "Unable to create data directory #{data_dir}: #{e}"
      raise "as_arclight failed start up due to error when creating data directory: #{e}"
    end

    ArclightIndexer.data_dir = data_dir
  end

  def initialize(backend = nil, state = nil, name)
    check_config_or_die!
    self.class.ensure_data_dir_or_die!

    state_class = Object.const_get(AppConfig[:index_state_class])
    index_state = state || state_class.new("indexer_arclight_state")

    super(backend, index_state, name)

    @time_to_sleep = AppConfig[:as_arclight_indexing_frequency_seconds]
    @thread_count = 1

    @uris_flagged_this_round = []

    # This preempts the login call in run_index_round so that we have a session
    # for the IndexVersion to do its business
    login

    IndexVersion.validate_config_or_die!

    if IndexVersion.reindex_required?
      reset_state_files
    end

    @failed_index_retry_delay_seconds = AppConfig[:as_arclight_failed_index_retry_delay_seconds] rescue 60 * 60

    @failed_index_max_failures = AppConfig[:as_arclight_failed_index_max_failures] rescue 100

    if AppConfig.has_key?(:as_arclight_reset_queue_on_start) && AppConfig[:as_arclight_reset_queue_on_start]
      ARCLog.warn 'Resetting queue!'
      JSONModel::HTTP.get_json('/as_arclight/remove_all_indexing_flags')
    end
  end

  def reset_state_files
    ARCLog.info "Resetting state files to trigger a full reindex"
    JSONModel(:repository).all.each do |repo|
      record_types.each do |record_type|
        ARCLog.debug "Resetting state file for repository: #{repo.id}, record type: #{record_type}"
        @state.set_last_mtime(repo.id, record_type, 0)
      end
    end

    ARCLog.debug "Resetting repositories state file"
    @state.set_last_mtime('repositories', 'repositories', 0)
    ARCLog.debug "Resetting deletes state file"
    @state.set_last_mtime('_deletes', 'deletes', 0)
  end

  def fetch_records(type, ids, resolve)
    result = []

    # id_set parameter is limited to :max_page_size so batch requests
    ids.each_slice(AppConfig[:max_page_size]) do |batch|
      JSONModel(type)
        .all(:id_set => batch.join(","), 'resolve[]' => resolve)
        .each do |json|
        if block_given?
          yield(json)
        else
          result << json
        end
      end
    end

    result
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
    uris_to_flag = uris.select{|uri| !@uris_flagged_this_round.include?(uri)}

    unless uris_to_flag.empty?
      resp = JSONModel::HTTP.get_json('/as_arclight/flag_for_indexing', 'uris[]' => uris_to_flag)
      @uris_flagged_this_round += resp['flagged']
    end
  end

  def flag_for_delete(*uris)
    JSONModel::HTTP.get_json('/as_arclight/flag_for_delete', 'uris[]' => uris)
  end

  def index_records(records, timing = IndexerTiming.new)
    # we don't index individual records
    # so all this needs to do is remember any affected resources
    records.each do |record|
      if reference = JSONModel.parse_reference(record['uri'])
        # skip records in unpublished repos - they are deleted when the repo is indexed
        if (reference[:type] == 'repository' && !record['record']['publish']) ||
            (reference[:type] != 'repository' && !record['record']['repository']['_resolved']['publish'])
          ARCLog.debug "Skipping record #{record['record']['uri']} because it is in an unpublished repository"
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
        ARCLog.error "Indexer couldn't parse uri #{record['uri']}"
      end
    end
  rescue
    ARCLog.exception($!)
    raise $!
  end

  def configure_doc_rules
  end

  def map_children(fh, waypoints_json, resource_uri, parent_uri, resource_json, first)
    fetched_child_records =
      fetch_records(:archival_object,
                    waypoints_json.map{|wp| JSONModel(:archival_object).id_for(wp.fetch('uri'))},
                    Arclight::Mapper.archival_object_mapper.resolves)
        .map{|record| [record.uri, record.to_hash(:trusted)]}
        .to_h

    # Manually resolve ancestors to avoid excessive memory usage
    # The child records are all children of the same parent,
    # so they have the same set of ancestors, so we only need
    # to fetch the ancestor data for the first one in the batch
    # and then apply the result to the whole batch
    #
    # drop the last ancestor - it is the resource and we don't need it
    ao_ancestors = fetched_child_records.values.first['ancestors'][0..-2]

    unless ao_ancestors.empty?
      ancestor_fields = JSONModel::HTTP.get_json('/as_arclight/ancestors',
                                                 'id_set[]' => ao_ancestors.map{|a| JSONModel.parse_reference(a['ref'])[:id]})
      ao_ancestors.zip(ancestor_fields).each do |aa, flds|
        aa['_resolved'] = flds
        aa['_resolved']['level'] = aa['level']
      end
    end

    # the ao mapper expects a top-to-bottom order
    ao_ancestors.reverse!

    waypoints_json.each do |waypoint_record|
      record_uri = waypoint_record.fetch('uri')
      child_count = waypoint_record.fetch('child_count')
      ao_json = fetched_child_records.fetch(record_uri)
      ao_json['resource'] ||= {}
      ao_json['resource']['_resolved'] = resource_json
      ao_json['_child_count'] = child_count
      ao_json['ancestors'] = ao_ancestors
      mapper = Arclight::Mapper.archival_object_mapper.new(ao_json)

      Arclight::Mapper.iiif_client.maybe_flush

      child_wp_json = nil

      if child_count > 0
        child_wp_json = JSONModel::HTTP.get_json(resource_uri + '/tree/node',
                                                 :node_uri => record_uri,
                                                 :published_only => true)
      end

      stream_doc(fh, mapper.json, resource_uri, record_uri, child_wp_json, resource_json, first)

      first = false
    end
  end

  def map_waypoints(fh, resource_uri, parent_uri, tree_json)
    tree_json.fetch('waypoints').times do |waypoint_number|
      waypoints_json = JSONModel::HTTP.get_json(resource_uri + '/tree/waypoint',
                                                :offset => waypoint_number,
                                                :parent_node => parent_uri,
                                                :published_only => true)

      map_children(fh, waypoints_json, resource_uri, parent_uri)
    end
  end

  def stream_doc(fh, doc, resource_uri, parent_uri, tree_json, resource_json, first)
    unless first
      fh.write(',')
    end

    if !tree_json || tree_json.fetch('child_count') == 0
      fh.write(doc)
    else
      fh.write(doc[0..-2])
      fh.write(',"components":[')

      tree_json.fetch('waypoints').times do |waypoint_number|
        waypoints_json = JSONModel::HTTP.get_json(resource_uri + '/tree/waypoint',
                                                  :offset => waypoint_number,
                                                  :parent_node => parent_uri,
                                                  :published_only => true)
        map_children(fh, waypoints_json, resource_uri, parent_uri, resource_json, first)
      end

      fh.write(']}')
    end
  end

  def stream_nested_resource_doc(resource_uri, resource_json)
    mapper = Arclight::Mapper.resource_mapper.new(resource_json)

    tree_root_json = JSONModel::HTTP.get_json(resource_uri + '/tree/root', :published_only => true)

    fh = Tempfile.new('arclight_stream.json')
    temp_file_path = fh.path
    ARCLog.debug "Dumping nested doc to #{temp_file_path}"

    begin
      fh.write('[')
      stream_doc(fh, mapper.json, resource_uri, nil, tree_root_json, resource_json, true)
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
      output_basename = resource_uri.gsub(/[^a-zA-Z0-9]/, '_')
      output_file = File.join(self_test_output_dir, output_basename + ".json")

      ARCLog.debug "Writing #{output_file} for further inspection"
      FileUtils.cp(fh.path, output_file + ".tmp")
      File.rename(output_file + ".tmp", output_file)
    end

    ARCLog.debug "Dump complete, sending to Solr targets ..."

    begin
      solr_targets.each do |target|
        send_delete_for_resource(resource_uri, 'it is about to be reindexed', target)

        req = request_for_target(target)
        req['Content-Length'] = File.size(temp_file_path)

        stream = File.open(temp_file_path, "rb")

        begin
          req.body_stream = stream
          resp = do_http_request(target.parsed_url, req)

          unless resp.code == '200'
            ARCLog.error "Error when streaming doc for #{resource_uri} to #{target.name}: #{resp.body}"
            next
          end
        ensure
          stream.close
        end

        if send_commit_for_target(target)
          ARCLog.info "Successfully indexed #{resource_uri} to #{target.name}"
        end
      end
    ensure
      File.unlink(temp_file_path)
    end
  end

  def send_delete_for_resource(resource_uri, reason, send_to_target = nil)
    delete_json = {'delete' => {'query' => "archivesspace_resource_uri_ssi:\"#{resource_uri}\""}}.to_json
    delete_length = delete_json.length

    (send_to_target ? [send_to_target] : solr_targets).each do |target|
      ARCLog.debug "Sending delete for #{resource_uri} and all its nested docs to #{target.name} because #{reason}"
      req = request_for_target(target)
      req['Content-Length'] = delete_length
      req.body = delete_json
      resp = do_http_request(target.parsed_url, req)

      if resp.code != '200'
        ARCLog.error "Error deleting #{resource_uri} from #{target.name}: #{resp.body}"
      end
    end
  end

  def run_index_round
    @uris_flagged_this_round = []

    super

    run_arclight_indexing
  end

  def run_arclight_indexing
    resource_count = 0
    indexed_count = 0
    deleted_count = 0
    unpublished_count = 0

    begin
      JSONModel::HTTP.get_json('/as_arclight/resources_to_delete').each do |resource_uri|
        send_delete_for_resource(resource_uri, 'it has been deleted in ArchivesSpace')
        deleted_count += 1
        resource_count += 1

        JSONModel::HTTP.get_json('/as_arclight/remove_delete_flag', :uri => resource_uri)
      end

      if deleted_count > 0
        send_commit_to_all_targets
      end

      # Clear any records that have reached our maximum number of failures
      max_failures = @failed_index_max_failures

      resp = JSONModel::HTTP.get_json('/as_arclight/resources_to_index', :max_failures => max_failures)

      resp['failed'].each do |failed|
        ARCLog.debug "Resource #{failed['uri']} has failed to index #{failed['failure_count']} times in a row and will be skipped"
      end

      ARCLog.info "There are #{resp['uris'].length} collections in need of indexing"

      fetch_records(:resource,
                    resp['uris'].map{|resource_uri| JSONModel(:resource).id_for(resource_uri)},
                    Arclight::Mapper.resource_mapper.resolves) do |resource_record|
        begin
          resource_uri = resource_record.uri
          resource_json = resource_record.to_hash(:trusted)

          resource_json.merge!(JSONModel::HTTP.get_json("/as_arclight#{resource_uri}"))

          if resource_json['publish'] && !resource_json['suppressed']
            ARCLog.debug "Preparing resource #{resource_uri}"

            stream_nested_resource_doc(resource_uri, resource_json)

            indexed_count += 1
          else
            unpublished_count += 1
            send_delete_for_resource(resource_uri, 'it is either unpublished or suppressed')
            send_commit_to_all_targets
          end

          JSONModel::HTTP.get_json('/as_arclight/remove_indexing_flag', 'uris[]' => resource_uri)

          resource_count += 1
        rescue => e
          next_retry_time = Time.now.to_i + @failed_index_retry_delay_seconds

          ARCLog.error "Error indexing resource #{resource_uri}: #{e}"
          ARCLog.error "This resource has been skipped and will be retried after #{Time.at(next_retry_time)}"
          ARCLog.exception(e)

          JSONModel::HTTP.get_json('/as_arclight/increment_failure_count', :uri => resource_uri, :next_retry => next_retry_time)
        end
      end

      if resource_count > 0
        ARCLog.info "Processed #{resource_count} resources. Indexed: #{indexed_count}, Deleted: #{deleted_count}, Unpublished: #{unpublished_count}"
      end
    rescue
      ARCLog.exception($!)
      raise $!
    ensure
      Arclight::Mapper.iiif_client.flush
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
              ARCLog.info "Deleted all documents in private repository #{repository['record']['repo_code']} for #{target.name}"
            end
          else
            ARCLog.error "failed to delete Arclight documents in private repository #{repository['record']['repo_code']} for #{target.name}: #{response.body}"
          end
        end
      end
    end
  end

  def self_test_mode
    @self_test_mode ||= (AppConfig[:as_arclight_test_mode] rescue nil)
  end
end
