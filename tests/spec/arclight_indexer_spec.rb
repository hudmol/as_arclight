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
  end

  let(:indexer) do
    ArclightIndexer.new(nil, nil, "arclight_indexer_test")
  end

  let(:arcdb) { indexer.instance_variable_get(:@db) }

  let(:http_request_log) { @http_request_log ||= [] }

  before(:each) do
    # The arclight indexer keeps its SQLite db at:
    #   /tmp/as_arclight_test_data/as_arclight/arclight_indexer.db
    # clear it between examples.
    arcdb.with_session do
      arcdb.transaction do |db|
        db[:resource].delete
        db[:document].delete
        db[:deleted_resource].delete
        db[:index_version].delete
      end
    end

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

  describe "#check_config_or_die!" do
    it "dies if :as_arclight_solr_targets isn't set" do
      allow(AppConfig).to receive(:has_key?).with(:as_arclight_solr_targets).and_return(false)
      expect{indexer.check_config_or_die!}.to raise_error(ArclightIndexer::ConfigurationError)
    end

    it "dies if :as_arclight_solr_targets isn't an array" do
      allow(AppConfig).to receive(:[]).with(:as_arclight_solr_targets).and_return("not an array")
      expect{indexer.check_config_or_die!}.to raise_error(ArclightIndexer::ConfigurationError)
    end

    it "dies if an :as_arclight_solr_targets entry lacks a :url key" do
      allow(AppConfig).to receive(:[]).with(:as_arclight_solr_targets).and_return([{:url => "this entry is good"},
                                                                                   {:not_url => "this entry is bad"}])
      expect{indexer.check_config_or_die!}.to raise_error(ArclightIndexer::ConfigurationError)
    end

    it "dies if :as_arclight_index_version isn't an integer" do
      allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return("not an integer")
      expect{indexer.check_config_or_die!}.to raise_error(ArclightIndexer::ConfigurationError)
    end

    it "dies if :as_arclight_indexing_frequency_seconds isn't set" do
      allow(AppConfig).to receive(:has_key?).with(:as_arclight_indexing_frequency_seconds).and_return(false)
      expect{indexer.check_config_or_die!}.to raise_error(ArclightIndexer::ConfigurationError)
    end

    it "dies if :as_arclight_indexing_frequency_seconds isn't an integer" do
      allow(AppConfig).to receive(:[]).with(:as_arclight_indexing_frequency_seconds).and_return("not an integer")
      expect{indexer.check_config_or_die!}.to raise_error(ArclightIndexer::ConfigurationError)
    end

    it "dies if :as_arclight_resource_id_prefix isn't a string" do
      allow(AppConfig).to receive(:[]).with(:as_arclight_resource_id_prefix).and_return(["not", "a", "string"])
      expect{indexer.check_config_or_die!}.to raise_error(ArclightIndexer::ConfigurationError)
    end

    it "dies if :as_arclight_archival_object_id_delimiter isn't a string" do
      allow(AppConfig).to receive(:[]).with(:as_arclight_archival_object_id_delimiter).and_return(["not", "a", "string"])
      expect{indexer.check_config_or_die!}.to raise_error(ArclightIndexer::ConfigurationError)
    end

  end

  describe "#ensure_data_dir_or_die!" do
    it "dies if it can't create the data directory" do
      allow(AppConfig).to receive(:[]).with(:data_directory).and_return("/definitely/not/a/path/that/exists")
      expect{indexer.class.ensure_data_dir_or_die!}.to raise_error(/as_arclight failed start up due to error when creating data directory/)
    end

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

  describe '#fetch_records' do
    let(:sample_records) { [ {:id => 1}, {:id => 2}, {:id => 3} ] }

    let(:jsonmodel) {
      records = sample_records

      Object.new.tap do |r|
        r.define_singleton_method(:all) do |opts|
          id_set = opts.fetch(:id_set).split(",").map {|s| Integer(s)}

          records.select {|record| id_set.include?(record.fetch(:id))}
        end
      end
    }

    before(:each) do
      allow(JSONModel).to receive(:JSONModel).with(:archival_object).and_return(jsonmodel)
    end

    it 'returns an array of records when called without a block' do
      [1, 1000].each do |page_size|
        allow(AppConfig).to receive(:[]).with(:max_page_size).and_return(page_size)

        expect(indexer.fetch_records(:archival_object, [1, 2, 3], {})).to eq(sample_records)
      end
    end

    it 'yields records when called with a block' do
      [1, 1000].each do |page_size|
        allow(AppConfig).to receive(:[]).with(:max_page_size).and_return(page_size)

        result = []
        indexer.fetch_records(:archival_object, [1, 2, 3], {}) do |record|
          result << record
        end

        expect(result).to eq(sample_records)
      end
    end

  end

  describe '#index_records' do
    let(:published_repo) { { '_resolved' => { 'publish' => true } } }
    let(:unpublished_repo) { { '_resolved' => { 'publish' => false } } }


    it 'flags a resource for indexing when its repository is published' do
      arcdb.with_session do
        indexer.index_records([
                                record_for('/repositories/2/resources/123', 'repository' => published_repo)
                              ])

        arcdb.transaction do |db|
          expect(db[:resource].select_map(:uri)).to eq(['/repositories/2/resources/123'])
        end
      end
    end

    it 'skips a resource whose repository is not published' do
      arcdb.with_session do
        indexer.index_records([
                                record_for('/repositories/2/resources/123', 'repository' => unpublished_repo)
                              ])

        arcdb.transaction do |db|
          expect(db[:resource].select_map(:uri)).to be_empty
        end
      end
    end

    it 'flags the parent resource when an archival object is updated' do
      arcdb.with_session do
        indexer.index_records([
                                record_for('/repositories/2/archival_objects/456',
                                           'repository' => published_repo,
                                           'resource' => { 'ref' => '/repositories/2/resources/123' })
                              ])

        arcdb.transaction do |db|
          expect(db[:resource].select_map(:uri)).to eq(['/repositories/2/resources/123'])
        end
      end
    end

    it 'skips an archival object whose repository is not published' do
      arcdb.with_session do
        indexer.index_records([
                                record_for('/repositories/2/archival_objects/456',
                                           'repository' => unpublished_repo,
                                           'resource' => { 'ref' => '/repositories/2/resources/123' })
                              ])

        arcdb.transaction do |db|
          expect(db[:resource].select_map(:uri)).to be_empty
        end
      end
    end

    it 'flags every resource a top container belongs to' do
      arcdb.with_session do
        indexer.index_records([
                                record_for('/repositories/2/top_containers/789',
                                           'repository' => published_repo,
                                           'collection' => [
                                             { 'ref' => '/repositories/2/resources/123' },
                                             { 'ref' => '/repositories/2/resources/124' }
                                           ])
                              ])

        arcdb.transaction do |db|
          expect(db[:resource].select_map(:uri)).to contain_exactly(
                                                      '/repositories/2/resources/123',
                                                      '/repositories/2/resources/124'
                                                    )
        end
      end
    end

    it 'skips a repository record that is not published' do
      arcdb.with_session do
        indexer.index_records([
                                record_for('/repositories/2', 'publish' => false)
                              ])

        arcdb.transaction do |db|
          expect(db[:resource].select_map(:uri)).to be_empty
        end
      end
    end

    it 'deduplicates resources flagged by more than one related record' do
      arcdb.with_session do
        indexer.index_records([
                                record_for('/repositories/2/resources/123', 'repository' => published_repo),
                                record_for('/repositories/2/archival_objects/456',
                                           'repository' => published_repo,
                                           'resource' => { 'ref' => '/repositories/2/resources/123' })
                              ])

        arcdb.transaction do |db|
          expect(db[:resource].select_map(:uri)).to eq(['/repositories/2/resources/123'])
        end
      end
    end

    it 'resets the failure count and retry time when a resource is re-flagged' do
      arcdb.with_session do
        arcdb.transaction do |db|
          db[:resource].insert(:uri => '/repositories/2/resources/123',
                               :failure_count => 7,
                               :next_retry_time => 99999)
        end

        indexer.index_records([
                                record_for('/repositories/2/resources/123', 'repository' => published_repo)
                              ])

        arcdb.transaction do |db|
          row = db[:resource].first(:uri => '/repositories/2/resources/123')
          expect(row[:failure_count]).to eq(0)
          expect(row[:next_retry_time]).to be_nil
        end
      end
    end
  end

  describe '#solr_url' do
    it 'raises if called' do
      expect { indexer.solr_url }.to raise_error("as_arclight plugin: unexpected call to #solr_url!")
    end
  end

  describe 'ArclightIndexer::SolrTarget' do
    it 'populates solr_targets from AppConfig' do
      allow(AppConfig).to receive(:has_key?).with(:as_arclight_solr_targets).and_return(true)
      allow(AppConfig).to receive(:[]).with(:as_arclight_solr_targets).and_return(
        [
         { :label => 'target one', :url => 'http://solr.example/core_one' },
         { :label => 'target two', :url => 'http://solr.example/core_two' },
         { :url => 'http://solr.example/core_three' },
         { :label => 'target four', :url => 'http://solr.example/core_four', :user => 'auth_user', :pass => 'auth_pass' },
        ]
      )

      expect(indexer.solr_targets.length).to eq(4)
      expect(indexer.solr_targets[0].label).to eq('target one')
      expect(indexer.solr_targets[0].name).to eq('target one')
      expect(indexer.solr_targets[0].parsed_url).to be_a(URI)
      expect(indexer.solr_targets[0].parsed_url.path).to eq('/core_one')
      expect(indexer.solr_targets[0].basic_auth_enabled?).to eq(false)

      expect(indexer.solr_targets[1].label).to eq('target two')
      expect(indexer.solr_targets[1].name).to eq('target two')
      expect(indexer.solr_targets[1].parsed_url).to be_a(URI)
      expect(indexer.solr_targets[1].parsed_url.path).to eq('/core_two')
      expect(indexer.solr_targets[1].basic_auth_enabled?).to eq(false)

      expect(indexer.solr_targets[2].name).to eq('http://solr.example/core_three')
      expect(indexer.solr_targets[2].basic_auth_enabled?).to eq(false)

      expect(indexer.solr_targets[3].label).to eq('target four')
      expect(indexer.solr_targets[3].name).to eq('target four')
      expect(indexer.solr_targets[3].parsed_url).to be_a(URI)
      expect(indexer.solr_targets[3].parsed_url.path).to eq('/core_four')
      expect(indexer.solr_targets[3].user).to eq('auth_user')
      expect(indexer.solr_targets[3].pass).to eq('auth_pass')
      expect(indexer.solr_targets[3].basic_auth_enabled?).to eq(true)
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
      rec.define_singleton_method(:to_hash) { |*| { 'uri' => uri, 'ancestors' => [] } }
      rec
    end

    before(:each) do
      allow(Arclight::Mapper).to receive(:archival_object_mapper).and_return(fake_ao_mapper)
    end

    describe '#map_children' do
      let(:ao_uri) { '/repositories/2/archival_objects/5' }

      it 'inserts a document row for each waypoint child' do
        arcdb.with_session do
          allow(indexer).to receive(:fetch_records).and_return([ao_record(ao_uri)])

          indexer.map_children([{ 'uri' => ao_uri, 'child_count' => 0 }], resource_uri, nil, {}, nil)

          arcdb.transaction do |db|
            rows = db[:document].all
            expect(rows.size).to eq(1)
            expect(rows.first[:resource_uri]).to eq(resource_uri)
            expect(rows.first[:parent_id]).to be_nil
            expect(JSON.parse(rows.first[:json])).to include('id' => ao_uri, 'child_count' => 0)
          end
        end
      end

      it 'recurses into grandchildren when a child has its own children' do
        arcdb.with_session do
          allow(indexer).to receive(:fetch_records).and_return([ao_record(ao_uri)])
          child_waypoints = { 'waypoints' => 1 }
          allow(JSONModel::HTTP).to receive(:get_json).and_return(child_waypoints)
          allow(indexer).to receive(:map_waypoints)

          indexer.map_children([{ 'uri' => ao_uri, 'child_count' => 3 }], resource_uri, nil, {}, nil)

          arcdb.transaction do |db|
            inserted_id = db[:document].select_map(:id).first
            expect(indexer).to have_received(:map_waypoints).with(child_waypoints, resource_uri, inserted_id, {}, ao_uri)
          end
        end
      end

      it 'skips recursion when the child node was deleted out from under us' do
        arcdb.with_session do
          allow(indexer).to receive(:fetch_records).and_return([ao_record(ao_uri)])
          allow(JSONModel::HTTP).to receive(:get_json).and_return(nil)
          allow(indexer).to receive(:map_waypoints)

          indexer.map_children([{ 'uri' => ao_uri, 'child_count' => 1 }], resource_uri, nil, {}, nil)

          expect(indexer).not_to have_received(:map_waypoints)
        end
      end
    end

    describe '#map_waypoints' do
      it 'fetches and maps each waypoint page' do
        arcdb.with_session do
          allow(JSONModel::HTTP).to receive(:get_json).and_return([{ 'uri' => 'x', 'child_count' => 0 }])
          allow(indexer).to receive(:map_children)

          indexer.map_waypoints({ 'waypoints' => 2 }, resource_uri, 7, {}, 'parent-uri')

          expect(JSONModel::HTTP).to have_received(:get_json).twice
          expect(indexer).to have_received(:map_children).twice
        end
      end

      it 'does nothing when there are no waypoints' do
        arcdb.with_session do
          allow(indexer).to receive(:map_children)

          indexer.map_waypoints({ 'waypoints' => 0 }, resource_uri, 7, {}, 'parent-uri')

          expect(indexer).not_to have_received(:map_children)
        end
      end
    end
  end

  describe '#stream_doc' do
    it 'writes a leaf document verbatim' do
      arcdb.with_session do

        id = arcdb.transaction do |db|
          db[:document].insert(:json => '{"id":"root"}')
        end
        io = StringIO.new

        indexer.stream_doc(id, io)

        expect(io.string).to eq('{"id":"root"}')
      end
    end

    it 'nests child documents under a components array' do
      arcdb.with_session do
        arcdb.transaction do |db|
          root = db[:document].insert(:json => '{"a":1}')

          db[:document].insert(:parent_id => root, :json => '{"b":2}')
          db[:document].insert(:parent_id => root, :json => '{"c":3}')
          io = StringIO.new

          indexer.stream_doc(root, io)

          expect(io.string).to eq('{"a":1,"components":[{"b":2},{"c":3}]}')
        end
      end
    end

    it 'recurses through multiple levels of nesting' do
      arcdb.with_session do
        arcdb.transaction do |db|
          root = db[:document].insert(:json => '{"a":1}')
          child = db[:document].insert(:parent_id => root, :json => '{"b":2}')
          db[:document].insert(:parent_id => child, :json => '{"c":3}')

          io = StringIO.new

          indexer.stream_doc(root, io)

          expect(io.string).to eq('{"a":1,"components":[{"b":2,"components":[{"c":3}]}]}')
        end
      end
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

    it 'deletes the doc and all of its nested docs and then streams it, to each solr target, and commits on a 200 response' do
      arcdb.with_session do
        root = arcdb.transaction do |db|
          db[:document].insert(:resource_uri => 'test-uri', :json => '{"id":"root"}')
        end

        delete_json = {'delete' => {'query' => "archivesspace_resource_uri_ssi:\"test-uri\""}}.to_json

        indexer.stream_nested_doc(root, 'test-uri')
        expect(http_request_log.size).to eq(2)
        expect(http_request_log[0][:request]['Content-Type']).to eq('application/json')
        expect(http_request_log[0][:request].body).to eq(delete_json)

        expect(indexer).to have_received(:send_commit_for_target)
      end
    end

    it 'logs a successful index when the commit succeeds' do
      arcdb.with_session do
        allow(indexer).to receive(:send_commit_for_target).and_return(true)
        allow(ARCLog).to receive(:info)
        root = arcdb.transaction do |db|
          db[:document].insert(:resource_uri => 'test-uri', :json => '{"id":"root"}')
        end

        indexer.stream_nested_doc(root, '/repositories/2/resources/77')

        expect(ARCLog).to have_received(:info).with(/Successfully indexed .* to/)
      end
    end

    it 'logs an error when streaming the document to a target fails' do
      arcdb.with_session do
        resp = Object.new
        resp.define_singleton_method(:code) { '500' }
        resp.define_singleton_method(:body) { 'boom' }
        allow(indexer).to receive(:do_http_request).and_return(resp)
        root = arcdb.transaction do |db|
          db[:document].insert(:resource_uri => 'test-uri', :json => '{"id":"root"}')
        end

        indexer.stream_nested_doc(root, '/repositories/2/resources/88')

        expect(ARCLog).to have_received(:error).with(/Error when streaming doc/)
      end
    end

    it 'writes a candidate copy of the doc for inspection in record_candidate mode' do
      arcdb.with_session do
        Dir.mktmpdir do |dir|
          allow(indexer).to receive(:self_test_mode).and_return(:record_candidate)
          allow(AppConfig).to receive(:[]).with(:as_arclight_test_candidate_directory).and_return(dir)

          root = arcdb.transaction do |db|
            db[:document].insert(:resource_uri => '/repositories/2/resources/55', :json => '{"id":"root"}')
          end

          indexer.stream_nested_doc(root, '/repositories/2/resources/55')

          written = Dir.glob(File.join(dir, '*.json'))
          expect(written.size).to eq(1)
          expect(File.read(written.first)).to eq('[{"id":"root"}]')
        end
      end
    end

    it 'writes a pristine copy of the doc for inspection in record_pristine mode' do
      arcdb.with_session do
        Dir.mktmpdir do |dir|
          allow(indexer).to receive(:self_test_mode).and_return(:record_pristine)
          allow(AppConfig).to receive(:[]).with(:as_arclight_test_pristine_directory).and_return(dir)

          root = arcdb.transaction do |db|
            db[:document].insert(:resource_uri => '/repositories/2/resources/56', :json => '{"id":"root"}')
          end
          indexer.stream_nested_doc(root, '/repositories/2/resources/56')

          expect(Dir.glob(File.join(dir, '*.json')).size).to eq(1)
        end
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
      # as_arclight and tree/root lookups
      allow(JSONModel::HTTP).to receive(:get_json).and_return({})
    end

    it 'indexes a published resource and clears it from the work queue' do
      arcdb.with_session do
        arcdb.transaction do |db|
          db[:resource].insert(:uri => resource_uri)
        end

        allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, true))
        allow(indexer).to receive(:map_waypoints)
        allow(indexer).to receive(:stream_nested_doc)

        indexer.index_round_complete(repository)

        expect(indexer).to have_received(:map_waypoints)
        expect(indexer).to have_received(:stream_nested_doc).with(anything, resource_uri)
        arcdb.transaction do |db|
          expect(db[:resource].select_map(:uri)).to be_empty
        end
      end
    end

    it 'deletes an unpublished resource from each solr target' do
      arcdb.with_session do
        arcdb.transaction do |db|
          db[:resource].insert(:uri => resource_uri)
        end
        allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, false))

        indexer.index_round_complete(repository)

        delete_request = JSON.parse(http_request_log.first[:request].body)
        expect(delete_request.dig('delete', 'query')).to eq("archivesspace_resource_uri_ssi:\"#{resource_uri}\"")
        expect(indexer).to have_received(:send_commit_to_all_targets)
        arcdb.transaction do |db|
          expect(db[:resource].select_map(:uri)).to be_empty
        end
      end
    end

    it 'records a failure count and a retry time when indexing raises' do
      arcdb.with_session do
        arcdb.transaction do |db|
          db[:resource].insert(:uri => resource_uri)
        end
        allow(ARCLog).to receive(:exception)
        allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, true))
        allow(indexer).to receive(:map_waypoints).and_raise('indexing blew up')

        indexer.index_round_complete(repository)

        row = arcdb.transaction do |db|
          db[:resource].first(:uri => resource_uri)
        end
        # the resource stays in the queue to be retried later
        expect(row[:failure_count]).to eq(1)
        expect(row[:next_retry_time]).not_to be_nil
      end
    end

    it 'accumulates the failure count across repeated indexing failures' do
      arcdb.with_session do
        arcdb.transaction do |db|
          db[:resource].insert(:uri => resource_uri, :failure_count => 3)
        end
        allow(ARCLog).to receive(:exception)
        allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, true))
        allow(indexer).to receive(:map_waypoints).and_raise('indexing blew up')

        indexer.index_round_complete(repository)

        arcdb.transaction do |db|
          expect(db[:resource].first(:uri => resource_uri)[:failure_count]).to eq(4)
        end
      end
    end

    it 'drops resources that have exceeded the maximum number of failures' do
      arcdb.with_session do
        max = indexer.instance_variable_get(:@failed_index_max_failures)
        arcdb.transaction do |db|
          db[:resource].insert(:uri => '/repositories/2/resources/123', :failure_count => max + 1)
          db[:resource].insert(:uri => '/repositories/2/resources/999', :failure_count => max)
        end
        allow(indexer).to receive(:fetch_records).and_return([])

        indexer.index_round_complete(repository)

        # the over-limit resource is removed, the at-limit one is kept for another try
        arcdb.transaction do |db|
          expect(db[:resource].select_map(:uri)).to eq(['/repositories/2/resources/999'])
        end
      end
    end

    it 'sends a delete and a commit for resources removed in ArchivesSpace' do
      arcdb.with_session do
        arcdb.transaction do |db|
          db[:deleted_resource].insert(:uri => resource_uri)
        end

        allow(indexer).to receive(:fetch_records).and_return([])
        allow(indexer).to receive(:send_delete_for_resource)

        indexer.index_round_complete(repository)

        expect(indexer).to have_received(:send_delete_for_resource).with(resource_uri, 'it has been deleted in ArchivesSpace')
        expect(indexer).to have_received(:send_commit_to_all_targets)
        # the resource is cleared from both the work queue and the deleted queue
        arcdb.transaction do |db|
          expect(db[:deleted_resource].select_map(:uri)).to be_empty
          expect(db[:resource].select_map(:uri)).to be_empty
        end
      end
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
      arcdb.with_session do
        indexer.flag_for_delete('/repositories/2/resources/123')
        arcdb.transaction do |db|
          expect(db[:deleted_resource].select_map(:uri)).to eq(['/repositories/2/resources/123'])
        end
      end
    end

    it 'skips uris that are not resource references' do
      arcdb.with_session do
        indexer.flag_for_delete('/repositories/2/archival_objects/456')
        arcdb.transaction do |db|
          expect(db[:deleted_resource].select_map(:uri)).to be_empty
        end
      end
    end

    it 'silently tolerates the same resource being flagged for deletion twice' do
      arcdb.with_session do
        indexer.flag_for_delete('/repositories/2/resources/123')
        expect {
          indexer.flag_for_delete('/repositories/2/resources/123')
        }.not_to raise_error
        arcdb.transaction do |db|
          expect(db[:deleted_resource].select_map(:uri)).to eq(['/repositories/2/resources/123'])
        end
      end
    end
  end

  describe '#flag_for_indexing' do
    it 'ignores uris that are not resource references' do
      arcdb.with_session do
        indexer.flag_for_indexing('/repositories/2/archival_objects/456')
        arcdb.transaction do |db|
          expect(db[:resource].select_map(:uri)).to be_empty
        end
      end
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

      indexer.send_delete_for_resource('/repositories/2/resources/9', 'we are testing deletes')

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
          seed.instance_variable_get(:@db).tap do |arcdb|
            arcdb.with_session do
              arcdb.transaction do |db|
                db[:resource].insert(:uri => '/repositories/2/resources/1')
              end
            end
          end

          allow(AppConfig).to receive(:has_key?).with(:as_arclight_reset_queue_on_start).and_return(true)
          allow(AppConfig).to receive(:[]).with(:as_arclight_reset_queue_on_start).and_return(true)
          allow(ARCLog).to receive(:warn)

          rerun = ArclightIndexer.new(nil, nil, 'reset-run')

          rerun.instance_variable_get(:@db).tap do |arcdb|
            arcdb.with_session do
              arcdb.transaction do |db|
                expect(db[:resource].select_map(:uri)).to be_empty
                expect(ARCLog).to have_received(:warn).with(/Resetting queue/)
              end
            end
          end
        end
      ensure
        ArclightIndexer.data_dir = original
      end
    end
  end

  describe '#record_types' do
    it 'returns an array of record types we care about' do
      expect(indexer.record_types).to eq([:resource, :archival_object, :top_container])
    end
  end

  describe '#reset_state_files' do
    let(:repositories) {
      [ {:id => 1}, {:id => 2}, {:id => 3} ].map do |sr|
        Object.new.tap do |r|
          r.define_singleton_method(:id) do
            sr[:id]
          end
        end
      end
    }

    let(:all_repositories) {
      repos = repositories
      Object.new.tap do |r|
        r.define_singleton_method(:all) do
          repos
        end
      end
    }

    it 'writes 0 to all state files' do
      allow(JSONModel).to receive(:JSONModel).with(:repository).and_return(all_repositories)
      state_dir = indexer.instance_variable_get(:@state).instance_variable_get(:@state_dir)
      indexer.reset_state_files
      Dir.glob(File.join(state_dir, '*.dat')).each do |state_file|
        expect(File.read(state_file).chomp).to eq('0')
      end
    end
  end
end
