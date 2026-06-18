require 'stringio'
require 'tmpdir'

describe 'ArclightIndexer' do
  before(:all) do
    mock_enum_source = Object.new.tap do |o|
      def o.values_for(enum_name)
        []
      end
    end

    JSONModel::init(enum_source: mock_enum_source)

    ArclightIndexer.data_dir = File.join(AppConfig[:data_directory], 'as_arclight')
  end

  let!(:indexer) do
    ArclightIndexer.new(nil, nil, "arclight_indexer_test")
  end

  let(:db) { indexer.instance_variable_get(:@db) }

  let(:http_request_log) { @http_request_log ||= [] }

  before(:each) do
    # The arclight indexer keeps its SQLite db at:
    #   /tmp/as_arclight_test_data/as_arclight/arclight_indexer.db
    # :resource table survives across instances, so clear it between examples.
    db[:resource].delete
    db[:document].delete
    db[:deleted_resource].delete

    # Silence log output unless an example sets its own expectation.
    allow(ARCLog).to receive(:debug)
    allow(ARCLog).to receive(:error)

    allow(indexer).to receive(:do_http_request) do |url, request|
      http_request_log.push(:url => url, :request => request)

      Object.new.tap do |o|
        def o.code
          '200'
        end
      end
    end
  end

  after(:each) do
    http_request_log = []
  end

  # Build a record in the shape index_records expects:
  #   { 'uri' => '...', 'record' => { ...full json... } }
  def record_for(uri, attrs = {})
    {
      'uri' => uri,
      'record' => { 'uri' => uri }.merge(attrs)
    }
  end

  describe '#repositories_updated_action' do
    let(:published_repo) { { 'record' => { 'publish' => true } } }
    let(:unpublished_repo) { { 'record' => { 'name' => 'unpublished_repo', 'publish' => false } } }

    it 'deletes all collections in unpublished repositories' do
      indexer.repositories_updated_action([unpublished_repo])
      delete_request = JSON.parse(http_request_log.first[:request].body)
      commit_request = JSON.parse(http_request_log.last[:request].body)

      expect(delete_request.dig('delete', 'query')).to eq('repository_ssim:"unpublished_repo"')
      expect(commit_request.dig('commit', 'softCommit')).to eq(false)
    end

    it 'leaves published repositories alone' do
      indexer.repositories_updated_action([published_repo])

      expect(http_request_log).to be_empty
    end

    it 'logs an error when deleting a private repository fails' do
      resp = Object.new
      resp.define_singleton_method(:code) { '500' }
      resp.define_singleton_method(:body) { 'nope' }
      allow(indexer).to receive(:do_http_request).and_return(resp)

      indexer.repositories_updated_action([
        { 'record' => { 'name' => 'priv', 'repo_code' => 'PRIV', 'publish' => false } }
      ])

      expect(ARCLog).to have_received(:error)
        .with(/failed to delete Arclight documents in private repository/)
    end
  end

  describe '#index_records' do
    let(:published_repo) { { '_resolved' => { 'publish' => true } } }
    let(:unpublished_repo) { { '_resolved' => { 'publish' => false } } }

    it 'flags a resource for indexing when its repository is published' do
      indexer.index_records([
                              record_for('/repositories/2/resources/123', 'repository' => published_repo)
                            ])

      expect(db[:resource].select_map(:uri)).to eq(['/repositories/2/resources/123'])
    end

    it 'skips a resource whose repository is not published' do
      indexer.index_records([
                              record_for('/repositories/2/resources/123', 'repository' => unpublished_repo)
                            ])

      expect(db[:resource].select_map(:uri)).to be_empty
    end

    it 'flags the parent resource when an archival object is updated' do
      indexer.index_records([
                              record_for('/repositories/2/archival_objects/456',
                                         'repository' => published_repo,
                                         'resource' => { 'ref' => '/repositories/2/resources/123' })
                            ])

      expect(db[:resource].select_map(:uri)).to eq(['/repositories/2/resources/123'])
    end

    it 'skips an archival object whose repository is not published' do
      indexer.index_records([
                              record_for('/repositories/2/archival_objects/456',
                                         'repository' => unpublished_repo,
                                         'resource' => { 'ref' => '/repositories/2/resources/123' })
                            ])

      expect(db[:resource].select_map(:uri)).to be_empty
    end

    it 'flags every resource a top container belongs to' do
      indexer.index_records([
                              record_for('/repositories/2/top_containers/789',
                                         'repository' => published_repo,
                                         'collection' => [
                                           { 'ref' => '/repositories/2/resources/123' },
                                           { 'ref' => '/repositories/2/resources/124' }
                                         ])
                            ])

      expect(db[:resource].select_map(:uri)).to contain_exactly(
                                                  '/repositories/2/resources/123',
                                                  '/repositories/2/resources/124'
                                                )
    end

    it 'skips a repository record that is not published' do
      indexer.index_records([
                              record_for('/repositories/2', 'publish' => false)
                            ])

      expect(db[:resource].select_map(:uri)).to be_empty
    end

    it 'deduplicates resources flagged by more than one related record' do
      indexer.index_records([
                              record_for('/repositories/2/resources/123', 'repository' => published_repo),
                              record_for('/repositories/2/archival_objects/456',
                                         'repository' => published_repo,
                                         'resource' => { 'ref' => '/repositories/2/resources/123' })
                            ])

      expect(db[:resource].select_map(:uri)).to eq(['/repositories/2/resources/123'])
    end

    it 'resets the failure count and retry time when a resource is re-flagged' do
      db[:resource].insert(:uri => '/repositories/2/resources/123',
                           :failure_count => 7,
                           :next_retry_time => 99999)

      indexer.index_records([
                              record_for('/repositories/2/resources/123', 'repository' => published_repo)
                            ])

      row = db[:resource].first(:uri => '/repositories/2/resources/123')
      expect(row[:failure_count]).to eq(0)
      expect(row[:next_retry_time]).to be_nil
    end
  end

  describe '#solr_url' do
    it 'raises if called' do
      expect { indexer.solr_url }.to raise_error("as_arclight plugin: unexpected call to #solr_url!")
    end
  end

  describe 'Solr authentication' do
    let(:auth_target) { ArclightIndexer::SolrTarget.new('http://solr.example/core', 'Solr', 'user', 'secret') }
    let(:noauth_target) { ArclightIndexer::SolrTarget.new('http://solr.example/core') }

    describe ArclightIndexer::SolrTarget do
      it 'reports basic auth enabled only when both user and pass are present' do
        expect(auth_target.basic_auth_enabled?).to be_truthy
        expect(noauth_target.basic_auth_enabled?).to be_falsey
        expect(ArclightIndexer::SolrTarget.new('http://x', 'l', 'user', nil).basic_auth_enabled?).to be_falsey
        expect(ArclightIndexer::SolrTarget.new('http://x', 'l', nil, 'pass').basic_auth_enabled?).to be_falsey
      end

      it 'uses the label as its name, falling back to the url' do
        expect(auth_target.name).to eq('Solr')
        expect(noauth_target.name).to eq('http://solr.example/core')
      end
    end

    describe '#request_for_target' do
      it 'posts to the /update path with a JSON content type and no auth by default' do
        req = indexer.request_for_target(noauth_target)

        expect(req.path).to eq('/core/update')
        expect(req['Content-Type']).to eq('application/json')
        expect(req['Authorization']).to be_nil
      end

      it 'adds basic auth when the target has credentials' do
        req = indexer.request_for_target(auth_target)

        expect(req['Authorization']).to eq('Basic ' + Base64.strict_encode64('user:secret'))
      end
    end
  end

  describe 'tree mapping' do
    let(:resource_uri) { '/repositories/2/resources/123' }

    # A stand-in mapper so we don't have to build a fully-resolved archival object.
    let(:fake_ao_mapper) do
      Class.new do
        def self.resolves
          []
        end

        def initialize(json)
          @json = json
        end

        def json
          JSON.dump('id' => @json['uri'], 'child_count' => @json['_child_count'])
        end
      end
    end

    def ao_record(uri)
      rec = Object.new
      rec.define_singleton_method(:uri) { uri }
      rec.define_singleton_method(:to_hash) { |*| { 'uri' => uri } }
      rec
    end

    before(:each) do
      allow(Arclight::Mapper).to receive(:archival_object_mapper).and_return(fake_ao_mapper)
    end

    describe '#map_children' do
      let(:ao_uri) { '/repositories/2/archival_objects/5' }

      it 'inserts a document row for each waypoint child' do
        allow(indexer).to receive(:fetch_records).and_return([ao_record(ao_uri)])

        indexer.map_children([{ 'uri' => ao_uri, 'child_count' => 0 }], resource_uri, nil, nil)

        rows = db[:document].all
        expect(rows.size).to eq(1)
        expect(rows.first[:resource_uri]).to eq(resource_uri)
        expect(rows.first[:parent_id]).to be_nil
        expect(JSON.parse(rows.first[:json])).to include('id' => ao_uri, 'child_count' => 0)
      end

      it 'recurses into grandchildren when a child has its own children' do
        allow(indexer).to receive(:fetch_records).and_return([ao_record(ao_uri)])
        child_waypoints = { 'waypoints' => 1 }
        allow(JSONModel::HTTP).to receive(:get_json).and_return(child_waypoints)
        allow(indexer).to receive(:map_waypoints)

        indexer.map_children([{ 'uri' => ao_uri, 'child_count' => 3 }], resource_uri, nil, nil)

        inserted_id = db[:document].select_map(:id).first
        expect(indexer).to have_received(:map_waypoints).with(child_waypoints, resource_uri, inserted_id, ao_uri)
      end

      it 'skips recursion when the child node was deleted out from under us' do
        allow(indexer).to receive(:fetch_records).and_return([ao_record(ao_uri)])
        allow(JSONModel::HTTP).to receive(:get_json).and_return(nil)
        allow(indexer).to receive(:map_waypoints)

        indexer.map_children([{ 'uri' => ao_uri, 'child_count' => 1 }], resource_uri, nil, nil)

        expect(indexer).not_to have_received(:map_waypoints)
      end
    end

    describe '#map_waypoints' do
      it 'fetches and maps each waypoint page' do
        allow(JSONModel::HTTP).to receive(:get_json).and_return([{ 'uri' => 'x', 'child_count' => 0 }])
        allow(indexer).to receive(:map_children)

        indexer.map_waypoints({ 'waypoints' => 2 }, resource_uri, 7, 'parent-uri')

        expect(JSONModel::HTTP).to have_received(:get_json).twice
        expect(indexer).to have_received(:map_children).twice
      end

      it 'does nothing when there are no waypoints' do
        allow(indexer).to receive(:map_children)

        indexer.map_waypoints({ 'waypoints' => 0 }, resource_uri, 7, 'parent-uri')

        expect(indexer).not_to have_received(:map_children)
      end
    end
  end

  describe '#stream_doc' do
    it 'writes a leaf document verbatim' do
      id = db[:document].insert(:json => '{"id":"root"}')
      io = StringIO.new

      indexer.stream_doc(id, io)

      expect(io.string).to eq('{"id":"root"}')
    end

    it 'nests child documents under a components array' do
      root = db[:document].insert(:json => '{"a":1}')
      db[:document].insert(:parent_id => root, :json => '{"b":2}')
      db[:document].insert(:parent_id => root, :json => '{"c":3}')
      io = StringIO.new

      indexer.stream_doc(root, io)

      expect(io.string).to eq('{"a":1,"components":[{"b":2},{"c":3}]}')
    end

    it 'recurses through multiple levels of nesting' do
      root = db[:document].insert(:json => '{"a":1}')
      child = db[:document].insert(:parent_id => root, :json => '{"b":2}')
      db[:document].insert(:parent_id => child, :json => '{"c":3}')
      io = StringIO.new

      indexer.stream_doc(root, io)

      expect(io.string).to eq('{"a":1,"components":[{"b":2,"components":[{"c":3}]}]}')
    end
  end

  describe '#stream_nested_doc' do
    let(:target) { ArclightIndexer::SolrTarget.new('http://solr.example/core') }

    before(:each) do
      allow(indexer).to receive(:solr_targets).and_return([target])
      allow(indexer).to receive(:send_commit_for_target)
      allow(indexer).to receive(:log)
      allow(indexer).to receive(:self_test_mode).and_return(nil)
    end

    it 'streams the doc to each solr target and commits on a 200 response' do
      root = db[:document].insert(:resource_uri => 'test-uri', :json => '{"id":"root"}')

      indexer.stream_nested_doc(root, 'test-uri')
      expect(http_request_log.size).to eq(1)
      expect(http_request_log.first[:request]['Content-Type']).to eq('application/json')
      expect(indexer).to have_received(:send_commit_for_target)
    end

    it 'logs a successful index when the commit succeeds' do
      allow(indexer).to receive(:send_commit_for_target).and_return(true)
      root = db[:document].insert(:resource_uri => 'test-uri', :json => '{"id":"root"}')

      indexer.stream_nested_doc(root, '/repositories/2/resources/77')

      expect(indexer).to have_received(:log).with(/Indexed .* to/)
    end

    it 'logs an error when streaming the document to a target fails' do
      resp = Object.new
      resp.define_singleton_method(:code) { '500' }
      resp.define_singleton_method(:body) { 'boom' }
      allow(indexer).to receive(:do_http_request).and_return(resp)
      root = db[:document].insert(:resource_uri => 'test-uri', :json => '{"id":"root"}')

      indexer.stream_nested_doc(root, '/repositories/2/resources/88')

      expect(ARCLog).to have_received(:error).with(/Error when streaming doc/)
    end

    it 'writes a candidate copy of the doc for inspection in record_candidate mode' do
      Dir.mktmpdir do |dir|
        allow(indexer).to receive(:self_test_mode).and_return(:record_candidate)
        allow(AppConfig).to receive(:[]).and_call_original
        allow(AppConfig).to receive(:[]).with(:as_arclight_test_candidate_directory).and_return(dir)

        root = db[:document].insert(:resource_uri => '/repositories/2/resources/55', :json => '{"id":"root"}')
        indexer.stream_nested_doc(root, '/repositories/2/resources/55')

        written = Dir.glob(File.join(dir, '*.json'))
        expect(written.size).to eq(1)
        expect(File.read(written.first)).to eq('[{"id":"root"}]')
      end
    end

    it 'writes a pristine copy of the doc for inspection in record_pristine mode' do
      Dir.mktmpdir do |dir|
        allow(indexer).to receive(:self_test_mode).and_return(:record_pristine)
        allow(AppConfig).to receive(:[]).and_call_original
        allow(AppConfig).to receive(:[]).with(:as_arclight_test_pristine_directory).and_return(dir)

        root = db[:document].insert(:resource_uri => '/repositories/2/resources/56', :json => '{"id":"root"}')
        indexer.stream_nested_doc(root, '/repositories/2/resources/56')

        expect(Dir.glob(File.join(dir, '*.json')).size).to eq(1)
      end
    end
  end

  describe '#index_round_complete' do
    let(:target) { ArclightIndexer::SolrTarget.new('http://solr.example/core') }
    let(:repository) { double('repository', repo_code: 'repo1') }
    let(:resource_uri) { '/repositories/2/resources/123' }

    let(:fake_resource_mapper) do
      Class.new do
        def self.resolves
          []
        end

        def initialize(json)
          @json = json
        end

        def json
          '{"id":"resource_doc"}'
        end

        def doc_id
          'resource_doc'
        end
      end
    end

    def resource_record(uri, publish)
      rec = Object.new
      rec.define_singleton_method(:uri) { uri }
      rec.define_singleton_method(:to_hash) { |*| { 'uri' => uri, 'publish' => publish } }
      rec
    end

    before(:each) do
      allow(indexer).to receive(:solr_targets).and_return([target])
      allow(indexer).to receive(:send_commit_to_all_targets)
      allow(indexer).to receive(:log)
      allow(Arclight::Mapper).to receive(:resource_mapper).and_return(fake_resource_mapper)
      # arclight_extras and tree/root lookups
      allow(JSONModel::HTTP).to receive(:get_json).and_return({})
    end

    it 'indexes a published resource and clears it from the work queue' do
      db[:resource].insert(:uri => resource_uri)
      allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, true))
      allow(indexer).to receive(:map_waypoints)
      allow(indexer).to receive(:stream_nested_doc)

      indexer.index_round_complete(repository)

      expect(indexer).to have_received(:map_waypoints)
      expect(indexer).to have_received(:stream_nested_doc).with(anything, resource_uri)
      expect(db[:resource].select_map(:uri)).to be_empty
    end

    it 'deletes an unpublished resource from each solr target' do
      db[:resource].insert(:uri => resource_uri)
      allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, false))

      indexer.index_round_complete(repository)

      delete_request = JSON.parse(http_request_log.first[:request].body)
      expect(delete_request.dig('delete', 'query')).to eq("archivesspace_uri_ssi:\"#{resource_uri}\"")
      expect(indexer).to have_received(:send_commit_to_all_targets)
      expect(db[:resource].select_map(:uri)).to be_empty
    end

    it 'records a failure count and a retry time when indexing raises' do

      db[:resource].insert(:uri => resource_uri)
      allow(ARCLog).to receive(:exception)
      allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, true))
      allow(indexer).to receive(:map_waypoints).and_raise('indexing blew up')

      indexer.index_round_complete(repository)

      row = db[:resource].first(:uri => resource_uri)
      # the resource stays in the queue to be retried later
      expect(row[:failure_count]).to eq(1)
      expect(row[:next_retry_time]).not_to be_nil
    end

    it 'accumulates the failure count across repeated indexing failures' do
      db[:resource].insert(:uri => resource_uri, :failure_count => 3)
      allow(ARCLog).to receive(:exception)
      allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, true))
      allow(indexer).to receive(:map_waypoints).and_raise('indexing blew up')

      indexer.index_round_complete(repository)

      expect(db[:resource].first(:uri => resource_uri)[:failure_count]).to eq(4)
    end

    it 'drops resources that have exceeded the maximum number of failures' do
      max = indexer.instance_variable_get(:@failed_index_max_failures)
      db[:resource].insert(:uri => '/repositories/2/resources/123', :failure_count => max + 1)
      db[:resource].insert(:uri => '/repositories/2/resources/999', :failure_count => max)
      allow(indexer).to receive(:fetch_records).and_return([])

      indexer.index_round_complete(repository)

      # the over-limit resource is removed, the at-limit one is kept for another try
      expect(db[:resource].select_map(:uri)).to eq(['/repositories/2/resources/999'])
    end

    it 'sends a delete and a commit for resources removed in ArchivesSpace' do
      db[:deleted_resource].insert(:uri => resource_uri)
      allow(indexer).to receive(:fetch_records).and_return([])
      allow(indexer).to receive(:send_delete_for_resource)

      indexer.index_round_complete(repository)

      expect(indexer).to have_received(:send_delete_for_resource).with(resource_uri)
      expect(indexer).to have_received(:send_commit_to_all_targets)
      # the resource is cleared from both the work queue and the deleted queue
      expect(db[:deleted_resource].select_map(:uri)).to be_empty
      expect(db[:resource].select_map(:uri)).to be_empty
    end
  end

  describe '#delete_records' do
    before(:each) { allow(indexer).to receive(:flag_for_delete) }

    it 'does nothing for an empty record set' do
      indexer.delete_records([])
      expect(indexer).not_to have_received(:flag_for_delete)
    end

    it 'flags a deleted resource for deletion' do
      indexer.delete_records(['/repositories/2/resources/123'])
      expect(indexer).to have_received(:flag_for_delete).with('/repositories/2/resources/123')
    end

    it 'ignores a deleted archival object - its resource will be reindexed' do
      indexer.delete_records(['/repositories/2/archival_objects/456'])
      expect(indexer).not_to have_received(:flag_for_delete)
    end

    it 'ignores other record types' do
      indexer.delete_records(['/repositories/2/top_containers/789'])
      expect(indexer).not_to have_received(:flag_for_delete)
    end
  end

  describe '#flag_for_delete' do
    it 'records a resource uri in the deleted_resource table' do
      indexer.flag_for_delete('/repositories/2/resources/123')
      expect(db[:deleted_resource].select_map(:uri)).to eq(['/repositories/2/resources/123'])
    end

    it 'skips uris that are not resource references' do
      indexer.flag_for_delete('/repositories/2/archival_objects/456')
      expect(db[:deleted_resource].select_map(:uri)).to be_empty
    end

    it 'silently tolerates the same resource being flagged for deletion twice' do
      indexer.flag_for_delete('/repositories/2/resources/123')
      expect {
        indexer.flag_for_delete('/repositories/2/resources/123')
      }.not_to raise_error
      expect(db[:deleted_resource].select_map(:uri)).to eq(['/repositories/2/resources/123'])
    end
  end

  describe '#flag_for_indexing' do
    it 'ignores uris that are not resource references' do
      indexer.flag_for_indexing('/repositories/2/archival_objects/456')
      expect(db[:resource].select_map(:uri)).to be_empty
    end
  end

  describe '#index_records error handling' do
    it 'logs an error when a record uri cannot be parsed' do
      allow(JSONModel).to receive(:parse_reference).and_return(nil)

      indexer.index_records([record_for('not-a-valid-uri')])

      expect(ARCLog).to have_received(:error).with(/couldn't parse uri/)
    end
  end

  describe '#send_commit_for_target' do
    let(:target) { ArclightIndexer::SolrTarget.new('http://solr.example/core', 'Solr') }

    def stub_commit_response(code, body = '')
      resp = Object.new
      resp.define_singleton_method(:code) { code }
      resp.define_singleton_method(:body) { body }
      allow(indexer).to receive(:do_http_request).and_return(resp)
    end

    it 'returns true on a 200 response' do
      stub_commit_response('200')
      expect(indexer.send_commit_for_target(target)).to be_truthy
    end

    it 'treats a maxWarmingSearchers response as a soft success and warns' do
      allow(ARCLog).to receive(:warn)
      stub_commit_response('400', 'exceeded limit of maxWarmingSearchers')

      expect(indexer.send_commit_for_target(target)).to be_truthy
      expect(ARCLog).to have_received(:warn).with(/Solr response when sending commit/)
    end

    it 'returns false and logs an error on any other failure' do
      stub_commit_response('500', 'kaboom')

      expect(indexer.send_commit_for_target(target)).to be_falsey
      expect(ARCLog).to have_received(:error).with(/Error when committing/)
    end
  end

  describe '#send_commit_to_all_targets' do
    it 'sends a commit to every configured target' do
      targets = [
        ArclightIndexer::SolrTarget.new('http://a/x'),
        ArclightIndexer::SolrTarget.new('http://b/y')
      ]
      allow(indexer).to receive(:solr_targets).and_return(targets)
      allow(indexer).to receive(:send_commit_for_target)

      indexer.send_commit_to_all_targets

      expect(indexer).to have_received(:send_commit_for_target).with(targets[0])
      expect(indexer).to have_received(:send_commit_for_target).with(targets[1])
    end
  end

  describe '#send_delete_for_resource' do
    let(:target) { ArclightIndexer::SolrTarget.new('http://solr.example/core') }

    before(:each) { allow(indexer).to receive(:solr_targets).and_return([target]) }

    it 'logs an error when a target responds with a non-200' do
      resp = Object.new
      resp.define_singleton_method(:code) { '503' }
      resp.define_singleton_method(:body) { 'down' }
      allow(indexer).to receive(:do_http_request).and_return(resp)

      indexer.send_delete_for_resource('/repositories/2/resources/9')

      expect(ARCLog).to have_received(:error).with(/Error deleting .* from/)
    end
  end

  describe 'indexer plumbing' do
    it '.get_indexer builds an ArclightIndexer instance' do
      expect(ArclightIndexer.get_indexer(nil, 'plumbing-get-indexer')).to be_a(ArclightIndexer)
    end

    it '#self_test_mode reads the configured test mode without raising' do
      expect { indexer.self_test_mode }.not_to raise_error
    end

    it '#solr_targets builds SolrTarget structs from configuration' do
      allow(AppConfig).to receive(:[]).and_call_original
      allow(AppConfig).to receive(:[]).with(:as_arclight_solr_targets).and_return([
        { :url => 'http://solr/core', :label => 'Primary', :user => 'u', :pass => 'p' }
      ])

      targets = indexer.solr_targets

      expect(targets.size).to eq(1)
      expect(targets.first.url).to eq('http://solr/core')
      expect(targets.first.label).to eq('Primary')
      expect(targets.first.basic_auth_enabled?).to be_truthy
    end
  end

  describe 'database initialization' do
    it 'empties the resource queue on start when as_arclight_reset_queue_on_start is set' do
      original = ArclightIndexer.data_dir
      begin
        Dir.mktmpdir do |dir|
          ArclightIndexer.data_dir = dir

          seed = ArclightIndexer.new(nil, nil, 'reset-seed')
          seed.instance_variable_get(:@db)[:resource].insert(:uri => '/repositories/2/resources/1')

          allow(AppConfig).to receive(:has_key?).and_call_original
          allow(AppConfig).to receive(:has_key?).with(:as_arclight_reset_queue_on_start).and_return(true)
          allow(AppConfig).to receive(:[]).and_call_original
          allow(AppConfig).to receive(:[]).with(:as_arclight_reset_queue_on_start).and_return(true)
          allow(ARCLog).to receive(:warn)

          rerun = ArclightIndexer.new(nil, nil, 'reset-run')

          expect(rerun.instance_variable_get(:@db)[:resource].select_map(:uri)).to be_empty
          expect(ARCLog).to have_received(:warn).with(/Resetting queue/)
        end
      ensure
        ArclightIndexer.data_dir = original
      end
    end
  end
end
