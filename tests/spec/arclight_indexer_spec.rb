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

    # Silence log output unless an example sets its own expectation.
    allow(Log).to receive(:debug)
    allow(Log).to receive(:error)

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
  end

  describe '#solr_url' do
    before(:each) do
      allow(indexer).to receive(:solr_urls).and_return([
                                                         URI.parse('http://solr-a.example/core'),
                                                         URI.parse('http://solr-b.example/core')
                                                       ])
    end

    it 'returns the first configured solr_url when no override is set' do
      expect(indexer.solr_url.to_s).to eq('http://solr-a.example/core')
    end

    it 'returns the override inside a run_for_solr_url block' do
      override = URI.parse('http://solr-b.example/core')
      indexer.run_for_solr_url(override) do
        expect(indexer.solr_url.to_s).to eq('http://solr-b.example/core')
      end
    end

    it 'clears the override after run_for_solr_url completes' do
      indexer.run_for_solr_url(URI.parse('http://solr-b.example/core')) do
      end

      expect(indexer.solr_url.to_s).to eq('http://solr-a.example/core')
    end

    it 'clears the override even if the block raises' do
      expect {
        indexer.run_for_solr_url(URI.parse('http://solr-b.example/core')) do
          raise 'boom'
        end
      }.to raise_error('boom')

      expect(indexer.solr_url.to_s).to eq('http://solr-a.example/core')
    end
  end
end
