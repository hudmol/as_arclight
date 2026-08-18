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

  # The indexer's state - which resources need indexing, which have been
  # deleted, how many times each has failed - lives in the ArchivesSpace
  # database and is reached through the as_arclight backend endpoints.  There's
  # no backend to talk to here, so we hand the indexer a FakeArclightBackend
  # (see spec/support/fake_arclight_backend.rb) and assert on the requests it
  # receives.  The 'backend state endpoints' section at the bottom of this file
  # covers the requests themselves.
  let(:indexer) do
    use_fake_backend(ArclightIndexer.new(nil, nil, "arclight_indexer_test"))
  end

  let(:http_request_log) { @http_request_log ||= [] }

  before(:each) do
    # IndexVersion checks the index version against the backend while the
    # indexer is being constructed
    stub_index_versions

    # Silence log output unless an example sets its own expectation.
    allow(ARCLog).to receive(:debug)
    allow(ARCLog).to receive(:error)

    allow(indexer).to receive(:do_http_request) do |url, request|
      http_request_log.push(:url => url, :request => request)

      Object.new.tap do |o|
        def o.code
          '200'
        end

        def o.body
          ''
        end
      end
    end
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

  describe 'startup' do
    it 'resets the indexer state when the index version requires a full reindex' do
      allow(IndexVersion).to receive(:reindex_required?).and_return(true)

      expect_any_instance_of(ArclightIndexer).to receive(:reset_state_files)

      ArclightIndexer.new(nil, nil, 'reindex-required')
    end

    it 'leaves the indexer state alone when no reindex is required' do
      allow(IndexVersion).to receive(:reindex_required?).and_return(false)

      expect_any_instance_of(ArclightIndexer).not_to receive(:reset_state_files)

      ArclightIndexer.new(nil, nil, 'no-reindex-required')
    end

    it 'clears the indexing queue when :as_arclight_reset_queue_on_start is set' do
      allow(AppConfig).to receive(:has_key?).with(:as_arclight_reset_queue_on_start).and_return(true)
      allow(AppConfig).to receive(:[]).with(:as_arclight_reset_queue_on_start).and_return(true)
      allow(ARCLog).to receive(:warn)
      allow(JSONModel::HTTP).to receive(:get_json).and_return('message' => 'success')

      ArclightIndexer.new(nil, nil, 'reset-queue-on-start')

      expect(JSONModel::HTTP).to have_received(:get_json).with('/as_arclight/remove_all_indexing_flags', {})
      expect(ARCLog).to have_received(:warn).with(/Resetting queue/)
    end

    it 'leaves the indexing queue alone by default' do
      allow(JSONModel::HTTP).to receive(:get_json).and_return('message' => 'success')

      ArclightIndexer.new(nil, nil, 'no-reset-queue-on-start')

      expect(JSONModel::HTTP).not_to have_received(:get_json)
        .with('/as_arclight/remove_all_indexing_flags', anything)
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
      indexer.index_records([
                              record_for('/repositories/2/resources/123', 'repository' => published_repo)
                            ])

      expect(fake_backend.flagged_for_indexing).to eq(['/repositories/2/resources/123'])
    end

    it 'skips a resource whose repository is not published' do
      indexer.index_records([
                              record_for('/repositories/2/resources/123', 'repository' => unpublished_repo)
                            ])

      expect(fake_backend.called?('/flag_for_indexing')).to be(false)
    end

    it 'flags the parent resource when an archival object is updated' do
      indexer.index_records([
                              record_for('/repositories/2/archival_objects/456',
                                         'repository' => published_repo,
                                         'resource' => { 'ref' => '/repositories/2/resources/123' })
                            ])

      expect(fake_backend.flagged_for_indexing).to eq(['/repositories/2/resources/123'])
    end

    it 'skips an archival object whose repository is not published' do
      indexer.index_records([
                              record_for('/repositories/2/archival_objects/456',
                                         'repository' => unpublished_repo,
                                         'resource' => { 'ref' => '/repositories/2/resources/123' })
                            ])

      expect(fake_backend.called?('/flag_for_indexing')).to be(false)
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

      expect(fake_backend.flagged_for_indexing).to contain_exactly(
                                                     '/repositories/2/resources/123',
                                                     '/repositories/2/resources/124'
                                                   )
    end

    it 'ignores the non-resource collections of a top container' do
      indexer.index_records([
                              record_for('/repositories/2/top_containers/789',
                                         'repository' => published_repo,
                                         'collection' => [
                                           { 'ref' => '/repositories/2/resources/123' },
                                           { 'ref' => '/repositories/2/accessions/9' }
                                         ])
                            ])

      expect(fake_backend.flagged_for_indexing).to eq(['/repositories/2/resources/123'])
    end

    it 'skips a repository record that is not published' do
      indexer.index_records([
                              record_for('/repositories/2', 'publish' => false)
                            ])

      expect(fake_backend.called?('/flag_for_indexing')).to be(false)
    end

    it 'deduplicates resources flagged by more than one related record' do
      indexer.index_records([
                              record_for('/repositories/2/resources/123', 'repository' => published_repo),
                              record_for('/repositories/2/archival_objects/456',
                                         'repository' => published_repo,
                                         'resource' => { 'ref' => '/repositories/2/resources/123' })
                            ])

      expect(fake_backend.requests_for('/flag_for_indexing').length).to eq(1)
      expect(fake_backend.flagged_for_indexing).to eq(['/repositories/2/resources/123'])
    end

    it 'logs an error when a record uri cannot be parsed' do
      allow(JSONModel).to receive(:parse_reference).and_return(nil)

      indexer.index_records([record_for('not-a-valid-uri')])

      expect(ARCLog).to have_received(:error).with(/couldn't parse uri/)
    end

    it 're-raises after logging when something goes wrong' do
      allow(ARCLog).to receive(:exception)
      allow(indexer).to receive(:flag_for_indexing).and_raise('flagging blew up')

      expect {
        indexer.index_records([
                                record_for('/repositories/2/resources/123', 'repository' => published_repo)
                              ])
      }.to raise_error(/flagging blew up/)

      expect(ARCLog).to have_received(:exception)
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

    # A stand-in mapper so we don't have to build a fully-resolved archival
    # object.  It hangs on to the last json it was handed so that examples can
    # check what we gave it.
    let(:fake_ao_mapper) do
      Class.new do
        class << self
          attr_accessor :last_json

          def resolves
            []
          end
        end

        def initialize(json)
          self.class.last_json = json
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

    # Stand in for a resource tree.  Keys are parent uris (nil for the resource
    # itself) and values are that parent's child uris.  Each parent's children
    # come back in a single waypoint page.
    def stub_tree(children_by_parent)
      uris = children_by_parent.values.flatten.uniq

      allow(indexer).to receive(:fetch_tree_waypoint) do |_resource_uri, parent_uri, _offset|
        (children_by_parent[parent_uri] || []).map do |uri|
          {'uri' => uri, 'child_count' => (children_by_parent[uri] || []).length}
        end
      end

      allow(indexer).to receive(:fetch_tree_node) do |_resource_uri, node_uri|
        {'child_count' => (children_by_parent[node_uri] || []).length, 'waypoints' => 1}
      end

      allow(indexer).to receive(:fetch_records) do |_type, ids, _resolves|
        ids.map {|id| ao_record(uris.detect {|uri| uri.end_with?("/#{id}")})}
      end
    end

    before(:each) do
      allow(Arclight::Mapper).to receive(:archival_object_mapper).and_return(fake_ao_mapper)
    end

    describe '#map_children' do
      let(:ao_uri) { '/repositories/2/archival_objects/5' }
      let(:sibling_uri) { '/repositories/2/archival_objects/6' }

      it 'streams a doc for each waypoint child' do
        stub_tree(nil => [ao_uri, sibling_uri])
        io = StringIO.new

        indexer.map_children(io,
                             [{'uri' => ao_uri, 'child_count' => 0},
                              {'uri' => sibling_uri, 'child_count' => 0}],
                             resource_uri, nil, {}, true)

        expect(JSON.parse("[#{io.string}]")).to eq([{'id' => ao_uri, 'child_count' => 0},
                                                    {'id' => sibling_uri, 'child_count' => 0}])
      end

      it 'writes a leading comma when it is continuing a list of docs' do
        stub_tree(nil => [ao_uri])
        io = StringIO.new

        indexer.map_children(io, [{'uri' => ao_uri, 'child_count' => 0}], resource_uri, nil, {}, false)

        expect(io.string).to start_with(',')
      end

      it 'reports back that a doc has been written' do
        stub_tree(nil => [ao_uri])
        io = StringIO.new

        expect(indexer.map_children(io, [{'uri' => ao_uri, 'child_count' => 0}], resource_uri, nil, {}, true))
          .to be(false)
      end

      it 'hands the resource and the child count to the mapper' do
        stub_tree(nil => [ao_uri])

        indexer.map_children(StringIO.new,
                             [{'uri' => ao_uri, 'child_count' => 4}],
                             resource_uri, nil, {'uri' => resource_uri}, true)

        expect(fake_ao_mapper.last_json['_child_count']).to eq(4)
        expect(fake_ao_mapper.last_json.dig('resource', '_resolved')).to eq('uri' => resource_uri)
      end

      it 'resolves the ancestors of the batch from the backend, top-to-bottom' do
        series_uri = '/repositories/2/archival_objects/1'
        file_uri = '/repositories/2/archival_objects/2'

        # ArchivesSpace gives us ancestors bottom-up, ending with the resource
        record = ao_record(ao_uri)

        hash_record = {
          'uri' => ao_uri,
          'ancestors' => [
            {'ref' => file_uri, 'level' => 'file'},
            {'ref' => series_uri, 'level' => 'series'},
            {'ref' => resource_uri, 'level' => 'collection'}
          ]
        }

        record.define_singleton_method(:to_hash) do |*|
          hash_record
        end

        allow(indexer).to receive(:fetch_records).and_return([record])
        allow(indexer).to receive(:ancestor_fields)
                            .and_return([{'display_string' => 'The file'},
                                         {'display_string' => 'The series'}])

        indexer.map_children(StringIO.new,
                             [{'uri' => ao_uri, 'child_count' => 0}],
                             resource_uri, nil, {}, true)

        # the resource is dropped - the mapper already has it
        expect(indexer).to have_received(:ancestor_fields)
                             .with([JSONModel.parse_reference(file_uri)[:id],
                                    JSONModel.parse_reference(series_uri)[:id]])

        ancestors = fake_ao_mapper.last_json['ancestors']
        expect(ancestors.map {|ancestor| ancestor['ref']}).to eq([series_uri, file_uri])
        expect(ancestors.first['_resolved']).to eq('display_string' => 'The series',
                                                   'level' => 'series')
      end

      it 'does not ask the backend for ancestors when there are none' do
        stub_tree(nil => [ao_uri])
        allow(indexer).to receive(:ancestor_fields)

        indexer.map_children(StringIO.new, [{'uri' => ao_uri, 'child_count' => 0}], resource_uri, nil, {}, true)

        expect(indexer).not_to have_received(:ancestor_fields)
      end

      it 'fetches the child tree node and recurses when a child has children' do
        stub_tree(nil => [ao_uri], ao_uri => ['/repositories/2/archival_objects/7'])
        allow(indexer).to receive(:map_waypoints)
        io = StringIO.new

        indexer.map_children(io, [{'uri' => ao_uri, 'child_count' => 1}], resource_uri, nil, {}, true)

        expect(indexer).to have_received(:fetch_tree_node).with(resource_uri, ao_uri)
        expect(indexer).to have_received(:map_waypoints)
                             .with(io, resource_uri, ao_uri,
                                   {'child_count' => 1, 'waypoints' => 1}, {}, true)
      end

      it 'streams a child as a leaf when its tree node was deleted out from under us' do
        stub_tree(nil => [ao_uri])
        allow(indexer).to receive(:fetch_tree_node).and_return(nil)
        allow(indexer).to receive(:map_waypoints)
        io = StringIO.new

        indexer.map_children(io, [{'uri' => ao_uri, 'child_count' => 1}], resource_uri, nil, {}, true)

        expect(indexer).not_to have_received(:map_waypoints)
        expect(JSON.parse(io.string)).to eq('id' => ao_uri, 'child_count' => 1)
      end
    end

    describe '#map_waypoints' do
      it 'fetches and maps each waypoint page' do
        allow(indexer).to receive(:fetch_tree_waypoint).and_return([{'uri' => 'x', 'child_count' => 0}])
        allow(indexer).to receive(:map_children).and_return(false)
        io = StringIO.new

        indexer.map_waypoints(io, resource_uri, 'parent-uri',
                              {'child_count' => 5, 'waypoints' => 2}, {}, true)

        expect(indexer).to have_received(:fetch_tree_waypoint).with(resource_uri, 'parent-uri', 0)
        expect(indexer).to have_received(:fetch_tree_waypoint).with(resource_uri, 'parent-uri', 1)
        expect(indexer).to have_received(:map_children).twice
      end

      it 'only lets the first page of children skip its separating comma' do
        allow(indexer).to receive(:fetch_tree_waypoint).and_return([{'uri' => 'x', 'child_count' => 0}])
        allow(indexer).to receive(:map_children).and_return(false)
        io = StringIO.new

        indexer.map_waypoints(io, resource_uri, 'parent-uri',
                              {'child_count' => 5, 'waypoints' => 2}, {}, true)

        expect(indexer).to have_received(:map_children)
                             .with(io, anything, resource_uri, 'parent-uri', {}, true).ordered
        expect(indexer).to have_received(:map_children)
                             .with(io, anything, resource_uri, 'parent-uri', {}, false).ordered
      end

      it 'does nothing when there are no waypoints' do
        allow(indexer).to receive(:map_children)

        expect(indexer.map_waypoints(StringIO.new, resource_uri, 'parent-uri',
                                     {'child_count' => 0, 'waypoints' => 0}, {}, true)).to be(true)

        expect(indexer).not_to have_received(:map_children)
      end
    end

    describe '#stream_doc' do
      let(:ao_one) { '/repositories/2/archival_objects/1' }
      let(:ao_two) { '/repositories/2/archival_objects/2' }
      let(:ao_three) { '/repositories/2/archival_objects/3' }
      let(:ao_four) { '/repositories/2/archival_objects/4' }

      it 'writes a leaf document verbatim' do
        io = StringIO.new

        indexer.stream_doc(io, '{"id":"root"}', resource_uri, nil, nil, {}, true)

        expect(io.string).to eq('{"id":"root"}')
      end

      it 'writes a separating comma when it is not the first document' do
        io = StringIO.new

        indexer.stream_doc(io, '{"id":"root"}', resource_uri, nil, nil, {}, false)

        expect(io.string).to eq(',{"id":"root"}')
      end

      it 'treats a childless tree node as a leaf' do
        allow(indexer).to receive(:fetch_tree_waypoint)
        io = StringIO.new

        indexer.stream_doc(io, '{"id":"root"}', resource_uri, nil,
                           {'child_count' => 0, 'waypoints' => 0}, {}, true)

        expect(io.string).to eq('{"id":"root"}')
        expect(indexer).not_to have_received(:fetch_tree_waypoint)
      end

      it 'nests child documents under a components array' do
        stub_tree(nil => [ao_one, ao_two])
        io = StringIO.new

        indexer.stream_doc(io, '{"id":"resource"}', resource_uri, nil,
                           {'child_count' => 2, 'waypoints' => 1}, {}, true)

        expect(JSON.parse(io.string)).to eq('id' => 'resource',
                                            'components' => [
                                              {'id' => ao_one, 'child_count' => 0},
                                              {'id' => ao_two, 'child_count' => 0}
                                            ])
      end

      it 'recurses through multiple levels of nesting' do
        stub_tree(nil => [ao_one, ao_two],
                  ao_one => [ao_three],
                  ao_two => [ao_four])
        io = StringIO.new

        indexer.stream_doc(io, '{"id":"resource"}', resource_uri, nil,
                           {'child_count' => 2, 'waypoints' => 1}, {}, true)

        expect(JSON.parse(io.string)).to eq(
                                          'id' => 'resource',
                                          'components' => [
                                            {'id' => ao_one, 'child_count' => 1,
                                             'components' => [{'id' => ao_three, 'child_count' => 0}]},
                                            {'id' => ao_two, 'child_count' => 1,
                                             'components' => [{'id' => ao_four, 'child_count' => 0}]}
                                          ])
      end

      it "writes valid JSON when a node's children span more than one waypoint page" do
        pages = [[{'uri' => ao_one, 'child_count' => 0}],
                 [{'uri' => ao_two, 'child_count' => 0}]]
        uris = [ao_one, ao_two]

        allow(indexer).to receive(:fetch_tree_waypoint) {|_resource_uri, _parent_uri, offset| pages[offset]}
        allow(indexer).to receive(:fetch_records) do |_type, ids, _resolves|
          ids.map {|id| ao_record(uris.detect {|uri| uri.end_with?("/#{id}")})}
        end
        io = StringIO.new

        indexer.stream_doc(io, '{"id":"resource"}', resource_uri, nil,
                           {'child_count' => 2, 'waypoints' => 2}, {}, true)

        expect(JSON.parse(io.string)['components'].map {|component| component['id']})
          .to eq([ao_one, ao_two])
      end
    end
  end

  describe '#stream_nested_resource_doc' do
    let(:target) { ArclightIndexer::SolrTarget.new('http://solr.example/core') }
    let(:resource_uri) { '/repositories/2/resources/55' }
    let(:resource_json) { {'uri' => resource_uri} }

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
      end
    end

    before(:each) do
      allow(indexer).to receive(:solr_targets).and_return([target])
      allow(indexer).to receive(:send_commit_for_target)
      allow(indexer).to receive(:log)
      allow(indexer).to receive(:self_test_mode).and_return(nil)
      allow(Arclight::Mapper).to receive(:resource_mapper).and_return(fake_resource_mapper)
      # a collection with no components
      allow(indexer).to receive(:fetch_tree_root).and_return('child_count' => 0, 'waypoints' => 0)
    end

    it 'reads the published tree root for the resource' do
      indexer.stream_nested_resource_doc(resource_uri, resource_json)

      expect(indexer).to have_received(:fetch_tree_root).with(resource_uri)
    end

    it 'deletes the doc and all of its nested docs and then streams it, to each solr target, and commits on a 200 response' do
      delete_json = {'delete' => {'query' => "archivesspace_resource_uri_ssi:\"#{resource_uri}\""}}.to_json

      indexer.stream_nested_resource_doc(resource_uri, resource_json)

      expect(http_request_log.size).to eq(2)
      expect(http_request_log[0][:request]['Content-Type']).to eq('application/json')
      expect(http_request_log[0][:request].body).to eq(delete_json)

      expect(indexer).to have_received(:send_commit_for_target)
    end

    it 'logs a successful index when the commit succeeds' do
      allow(indexer).to receive(:send_commit_for_target).and_return(true)
      allow(ARCLog).to receive(:info)

      indexer.stream_nested_resource_doc(resource_uri, resource_json)

      expect(ARCLog).to have_received(:info).with(/Successfully indexed .* to/)
    end

    it 'logs an error when streaming the document to a target fails' do
      resp = Object.new
      resp.define_singleton_method(:code) { '500' }
      resp.define_singleton_method(:body) { 'boom' }
      allow(indexer).to receive(:do_http_request).and_return(resp)

      indexer.stream_nested_resource_doc(resource_uri, resource_json)

      expect(ARCLog).to have_received(:error).with(/Error when streaming doc/)
    end

    it 'cleans up its temp file' do
      temp_file_paths = []
      allow(indexer).to receive(:do_http_request) do |_url, request|
        temp_file_paths << request.body_stream.path if request.body_stream

        Object.new.tap {|o| o.define_singleton_method(:code) { '200' }}
      end

      indexer.stream_nested_resource_doc(resource_uri, resource_json)

      expect(temp_file_paths).not_to be_empty
      temp_file_paths.each do |path|
        expect(File.exist?(path)).to be(false)
      end
    end

    it 'writes a candidate copy of the doc for inspection in record_candidate mode' do
      Dir.mktmpdir do |dir|
        allow(indexer).to receive(:self_test_mode).and_return(:record_candidate)
        allow(AppConfig).to receive(:[]).with(:as_arclight_test_candidate_directory).and_return(dir)

        indexer.stream_nested_resource_doc(resource_uri, resource_json)

        written = Dir.glob(File.join(dir, '*.json'))
        expect(written.size).to eq(1)
        expect(File.basename(written.first)).to eq('_repositories_2_resources_55.json')
        expect(File.read(written.first)).to eq('[{"id":"resource_doc"}]')
      end
    end

    it 'writes a pristine copy of the doc for inspection in record_pristine mode' do
      Dir.mktmpdir do |dir|
        allow(indexer).to receive(:self_test_mode).and_return(:record_pristine)
        allow(AppConfig).to receive(:[]).with(:as_arclight_test_pristine_directory).and_return(dir)

        indexer.stream_nested_resource_doc(resource_uri, resource_json)

        expect(Dir.glob(File.join(dir, '*.json')).size).to eq(1)
      end
    end
  end

  describe '#run_arclight_indexing' do
    let(:target) { ArclightIndexer::SolrTarget.new('http://solr.example/core') }
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
      end
    end

    def resource_record(uri, publish, suppressed = false)
      rec = Object.new
      rec.define_singleton_method(:uri) { uri }
      rec.define_singleton_method(:to_hash) do |*|
        {'uri' => uri, 'publish' => publish, 'suppressed' => suppressed}
      end
      rec
    end

    # The backend hands us the queue of resources that need indexing
    def queue_for_indexing(uris, failed = [])
      fake_backend.stub('/resources_to_index', {'uris' => uris, 'failed' => failed})
    end

    before(:each) do
      allow(indexer).to receive(:solr_targets).and_return([target])
      allow(indexer).to receive(:send_commit_to_all_targets)
      allow(indexer).to receive(:log)
      allow(indexer).to receive(:stream_nested_resource_doc)
      allow(Arclight::Mapper).to receive(:resource_mapper).and_return(fake_resource_mapper)
      allow(indexer).to receive(:fetch_records)
    end

    it 'asks the backend for the queued resources, passing our failure limit' do
      indexer.run_arclight_indexing

      expect(fake_backend.params_for('/resources_to_index'))
        .to eq([{:max_failures => indexer.instance_variable_get(:@failed_index_max_failures)}])
    end

    it 'only fetches the resources the backend gave us' do
      queue_for_indexing([resource_uri])
      fetched = nil
      allow(indexer).to receive(:fetch_records) do |type, ids, resolves|
        fetched = {:type => type, :ids => ids.map(&:to_s), :resolves => resolves}
      end

      indexer.run_arclight_indexing

      expect(fetched).to eq(:type => :resource, :ids => ['123'], :resolves => [])
    end

    it 'logs the resources the backend has given up on' do
      queue_for_indexing([], [{'uri' => '/repositories/2/resources/666', 'failure_count' => 101}])

      indexer.run_arclight_indexing

      expect(ARCLog).to have_received(:debug)
                          .with(%r{Resource /repositories/2/resources/666 has failed to index 101 times})
    end

    it 'indexes a published resource and removes its indexing flag' do
      queue_for_indexing([resource_uri])
      fake_backend.stub(resource_uri, {'_total_components' => 3})
      allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, true))

      indexer.run_arclight_indexing

      expect(indexer).to have_received(:stream_nested_resource_doc)
                           .with(resource_uri, hash_including('_total_components' => 3,
                                                              'publish' => true))
      expect(fake_backend.unflagged_for_indexing).to eq([resource_uri])
      expect(fake_backend.called?('/increment_failure_count')).to be(false)
    end

    it 'deletes an unpublished resource from each solr target rather than indexing it' do
      queue_for_indexing([resource_uri])
      allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, false))

      indexer.run_arclight_indexing

      delete_request = JSON.parse(http_request_log.first[:request].body)
      expect(delete_request.dig('delete', 'query')).to eq("archivesspace_resource_uri_ssi:\"#{resource_uri}\"")
      expect(indexer).to have_received(:send_commit_to_all_targets)
      expect(indexer).not_to have_received(:stream_nested_resource_doc)
      expect(fake_backend.unflagged_for_indexing).to eq([resource_uri])
    end

    it 'deletes a suppressed resource from each solr target rather than indexing it' do
      queue_for_indexing([resource_uri])
      allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, true, true))

      indexer.run_arclight_indexing

      expect(indexer).not_to have_received(:stream_nested_resource_doc)
      expect(http_request_log).not_to be_empty
      expect(fake_backend.unflagged_for_indexing).to eq([resource_uri])
    end

    it 'records a failure and a retry time when indexing raises' do
      queue_for_indexing([resource_uri])
      allow(ARCLog).to receive(:exception)
      allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, true))
      allow(indexer).to receive(:stream_nested_resource_doc).and_raise('indexing blew up')

      indexer.run_arclight_indexing

      failures = fake_backend.failures_recorded
      expect(failures.length).to eq(1)
      expect(failures.first[:uri]).to eq(resource_uri)
      expect(failures.first[:next_retry])
        .to be_within(30).of(Time.now.to_i + indexer.instance_variable_get(:@failed_index_retry_delay_seconds))

      # the resource stays flagged so that it gets retried
      expect(fake_backend.called?('/remove_indexing_flag')).to be(false)
      expect(ARCLog).to have_received(:error).with(/Error indexing resource/)
    end

    it 'keeps going after a resource fails to index' do
      other_uri = '/repositories/2/resources/124'
      queue_for_indexing([resource_uri, other_uri])
      allow(ARCLog).to receive(:exception)
      allow(indexer).to receive(:fetch_records)
                          .and_yield(resource_record(resource_uri, true))
                          .and_yield(resource_record(other_uri, true))
      allow(indexer).to receive(:stream_nested_resource_doc) do |uri, _json|
        raise 'indexing blew up' if uri == resource_uri
      end

      indexer.run_arclight_indexing

      expect(fake_backend.failures_recorded.map {|params| params[:uri]}).to eq([resource_uri])
      expect(fake_backend.unflagged_for_indexing).to eq([other_uri])
    end

    it 'sends a delete and a commit for resources removed in ArchivesSpace' do
      fake_backend.stub('/resources_to_delete', [resource_uri])
      allow(indexer).to receive(:send_delete_for_resource)

      indexer.run_arclight_indexing

      expect(indexer).to have_received(:send_delete_for_resource)
                           .with(resource_uri, 'it has been deleted in ArchivesSpace')
      expect(indexer).to have_received(:send_commit_to_all_targets)
      expect(fake_backend.unflagged_for_delete).to eq([resource_uri])
    end

    it 'does not commit when there was nothing to delete' do
      indexer.run_arclight_indexing

      expect(indexer).not_to have_received(:send_commit_to_all_targets)
    end

    it 'reports what it did when it did something' do
      queue_for_indexing([resource_uri])
      allow(ARCLog).to receive(:info)
      allow(indexer).to receive(:fetch_records).and_yield(resource_record(resource_uri, true))

      indexer.run_arclight_indexing

      expect(ARCLog).to have_received(:info)
                          .with('Processed 1 resources. Indexed: 1, Deleted: 0, Unpublished: 0')
    end

    it 'flushes the iiif client on the way out, even when something goes wrong' do
      iiif_client = double('iiif_client')
      allow(iiif_client).to receive(:flush)
      allow(Arclight::Mapper).to receive(:iiif_client).and_return(iiif_client)
      allow(ARCLog).to receive(:exception)
      allow(indexer).to receive(:resources_to_delete).and_raise('the backend is down')

      expect { indexer.run_arclight_indexing }.to raise_error(/the backend is down/)

      expect(iiif_client).to have_received(:flush)
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
    it 'asks the backend to flag the uris for deletion' do
      indexer.flag_for_delete('/repositories/2/resources/123', '/repositories/2/resources/124')

      expect(fake_backend.flagged_for_delete).to eq(['/repositories/2/resources/123',
                                                     '/repositories/2/resources/124'])
    end
  end

  describe '#flag_for_indexing' do
    let(:resource_uri) { '/repositories/2/resources/123' }

    it 'asks the backend to flag the uris for indexing' do
      indexer.flag_for_indexing(resource_uri, '/repositories/2/resources/124')

      expect(fake_backend.flagged_for_indexing).to eq([resource_uri,
                                                       '/repositories/2/resources/124'])
    end

    it 'makes no request when there is nothing to flag' do
      indexer.flag_for_indexing

      expect(fake_backend.called?('/flag_for_indexing')).to be(false)
    end

    it 'only asks once per uri per round' do
      indexer.flag_for_indexing(resource_uri)
      indexer.flag_for_indexing(resource_uri)

      expect(fake_backend.requests_for('/flag_for_indexing').length).to eq(1)
    end

    it 'asks again for a uri the backend declined to flag' do
      # the backend only flags resource uris
      fake_backend.stub('/flag_for_indexing') do |params|
        {'flagged' => [], 'not_flagged' => params['uris[]']}
      end

      indexer.flag_for_indexing('/repositories/2/archival_objects/456')
      indexer.flag_for_indexing('/repositories/2/archival_objects/456')

      expect(fake_backend.requests_for('/flag_for_indexing').length).to eq(2)
    end
  end

  # Everything above mocks out the backend.  These examples are where we pin
  # down the requests the mocked methods actually make.
  describe 'backend state endpoints' do
    # a plain indexer - the point here is the real #backend_get
    let(:indexer) { ArclightIndexer.new(nil, nil, 'backend_endpoint_test') }

    let(:resource_uri) { '/repositories/2/resources/123' }

    before(:each) do
      allow(JSONModel::HTTP).to receive(:get_json).and_return('flagged' => [])
    end

    def expect_request(path, params = {})
      expect(JSONModel::HTTP).to have_received(:get_json).with(path, params)
    end

    it 'flags uris for indexing' do
      indexer.flag_uris_for_indexing([resource_uri])

      expect_request('/as_arclight/flag_for_indexing', 'uris[]' => [resource_uri])
    end

    it 'removes indexing flags' do
      indexer.remove_indexing_flag(resource_uri)

      expect_request('/as_arclight/remove_indexing_flag', 'uris[]' => [resource_uri])
    end

    it 'removes all indexing flags' do
      indexer.remove_all_indexing_flags

      expect_request('/as_arclight/remove_all_indexing_flags')
    end

    it 'asks for the resources to index' do
      indexer.resources_to_index(100)

      expect_request('/as_arclight/resources_to_index', :max_failures => 100)
    end

    it 'increments a failure count' do
      indexer.increment_failure_count(resource_uri, 1234567890)

      expect_request('/as_arclight/increment_failure_count',
                     :uri => resource_uri,
                     :next_retry => 1234567890)
    end

    it 'flags uris for delete' do
      indexer.flag_uris_for_delete([resource_uri])

      expect_request('/as_arclight/flag_for_delete', 'uris[]' => [resource_uri])
    end

    it 'asks for the resources to delete' do
      indexer.resources_to_delete

      expect_request('/as_arclight/resources_to_delete')
    end

    it 'removes a delete flag' do
      indexer.remove_delete_flag(resource_uri)

      expect_request('/as_arclight/remove_delete_flag', :uri => resource_uri)
    end

    it 'asks for the extra resource summary data' do
      indexer.resource_summary_data(resource_uri)

      expect_request("/as_arclight#{resource_uri}")
    end

    it 'asks for the fields it needs to resolve ancestors' do
      indexer.ancestor_fields([1, 2, 3])

      expect_request('/as_arclight/ancestors', 'id_set[]' => [1, 2, 3])
    end

    it 'asks for the published tree root' do
      indexer.fetch_tree_root(resource_uri)

      expect_request("#{resource_uri}/tree/root", :published_only => true)
    end

    it 'asks for a published tree node' do
      indexer.fetch_tree_node(resource_uri, '/repositories/2/archival_objects/5')

      expect_request("#{resource_uri}/tree/node",
                     :node_uri => '/repositories/2/archival_objects/5',
                     :published_only => true)
    end

    it 'asks for a published tree waypoint' do
      indexer.fetch_tree_waypoint(resource_uri, '/repositories/2/archival_objects/5', 2)

      expect_request("#{resource_uri}/tree/waypoint",
                     :offset => 2,
                     :parent_node => '/repositories/2/archival_objects/5',
                     :published_only => true)
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
