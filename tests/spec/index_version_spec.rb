describe 'IndexVersion' do

  describe '#ensure_config!' do
    it 'sets a default for :as_arclight_index_version' do
      allow(AppConfig).to receive(:has_key?).with(:as_arclight_index_version).and_return(false)
      IndexVersion.ensure_config!
      expect(AppConfig[:as_arclight_index_version]).to eq(1)
    end

    it 'sets a default for :as_arclight_resource_id_prefix' do
      allow(AppConfig).to receive(:has_key?).with(:as_arclight_resource_id_prefix).and_return(false)
      IndexVersion.ensure_config!
      expect(AppConfig[:as_arclight_resource_id_prefix]).to eq('')
    end

    it 'sets a default for :as_arclight_archival_object_id_delimiter' do
      allow(AppConfig).to receive(:has_key?).with(:as_arclight_archival_object_id_delimiter).and_return(false)
      IndexVersion.ensure_config!
      expect(AppConfig[:as_arclight_archival_object_id_delimiter]).to eq('_')
    end
  end

  # Index versions live in the ArchivesSpace database, and we reach them through
  # the as_arclight backend endpoints.  IndexVersion.fetch_index_versions and
  # IndexVersion.create_index_version are the only places that happens, so
  # they're what we mock here.  The 'backend requests' examples at the bottom of
  # this file pin down the requests those two methods make.
  describe '#validate_config_or_die!' do

    # The version rows the backend hands back, in ascending version order
    def stub_backend_versions(versions)
      allow(IndexVersion).to receive(:fetch_index_versions).and_return(versions)
      allow(IndexVersion).to receive(:create_index_version)
    end

    # A row as the backend would return it for the config we're running with
    def current_version_row(version_number)
      {
        'id' => version_number,
        'version' => version_number,
        'config_hash' => IndexVersion.generate_index_version_hash
      }
    end

    before(:each) do
      allow(ARCLog).to receive(:info)
      allow(ARCLog).to receive(:debug)
      allow(ARCLog).to receive(:error)

      # #reindex_required? is sticky class state, so don't let it leak between
      # examples
      IndexVersion.instance_variable_set(:@reindex_required, false)
    end

    after(:each) do
      IndexVersion.instance_variable_set(:@reindex_required, false)
    end

    it 'creates an initial index version on a first run' do
      stub_backend_versions([])

      IndexVersion.validate_config_or_die!

      expect(IndexVersion).to have_received(:create_index_version)
                                .with(1, IndexVersion.generate_index_version_hash)
      expect(IndexVersion.reindex_required?).to be_falsey
    end

    it 'accepts a version whose config is unchanged, without touching the backend' do
      stub_backend_versions([current_version_row(1)])

      IndexVersion.validate_config_or_die!

      expect(IndexVersion).not_to have_received(:create_index_version)
      expect(IndexVersion.reindex_required?).to be_falsey
    end

    it 'compares against the highest version the backend knows about' do
      allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(2)
      stub_backend_versions([current_version_row(1), current_version_row(2)])

      IndexVersion.validate_config_or_die!

      expect(IndexVersion).not_to have_received(:create_index_version)
      expect(IndexVersion.reindex_required?).to be_falsey
    end

    it 'records the new version and requires a reindex when the version has increased' do
      allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(2)
      stub_backend_versions([current_version_row(1)])

      IndexVersion.validate_config_or_die!

      expect(IndexVersion).to have_received(:create_index_version)
                                .with(2, IndexVersion.generate_index_version_hash)
      expect(IndexVersion.reindex_required?).to be_truthy
    end

    it 'dies if the index version has decreased' do
      allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(0)
      stub_backend_versions([current_version_row(1)])

      expect {
        IndexVersion.validate_config_or_die!
      }.to raise_error(IndexVersion::ConfigurationError)

      expect(IndexVersion).not_to have_received(:create_index_version)
    end

    it 'dies if the config has changed but the version has not' do
      stub_backend_versions([current_version_row(1)])
      allow(AppConfig).to receive(:[]).with(:as_arclight_resource_id_prefix).and_return('new prefix')

      expect {
        IndexVersion.validate_config_or_die!
      }.to raise_error(IndexVersion::ConfigurationError)

      expect(IndexVersion).not_to have_received(:create_index_version)
      expect(IndexVersion.reindex_required?).to be_falsey
    end

    it 'tells you how to get back to the config the current index was built with' do
      stub_backend_versions([current_version_row(1)])
      allow(AppConfig).to receive(:[]).with(:as_arclight_resource_id_prefix).and_return('new prefix')

      expect {
        IndexVersion.validate_config_or_die!
      }.to raise_error(IndexVersion::ConfigurationError)

      expect(ARCLog).to have_received(:error).with(/To stay on the current index version, revert config to/)
      expect(ARCLog).to have_received(:error).with(/AppConfig\[:as_arclight_resource_id_prefix\]/)
    end

    it 'tells you to revert the plugin when the current index predates a config setting' do
      # an index built by a version of the plugin that didn't know about
      # :as_arclight_archival_object_id_delimiter
      stub_backend_versions([{
                              'version' => 1,
                              'config_hash' => {:as_arclight_resource_id_prefix => ''}.to_json
                            }])

      expect {
        IndexVersion.validate_config_or_die!
      }.to raise_error(IndexVersion::ConfigurationError)

      expect(ARCLog).to have_received(:error)
                          .with(/you need to revert your plugin version to one compatible with your index/)
    end
  end

  describe 'backend requests' do
    it 'reads the index versions from the as_arclight backend' do
      allow(JSONModel::HTTP).to receive(:get_json).and_return([])

      expect(IndexVersion.fetch_index_versions).to eq([])
      expect(JSONModel::HTTP).to have_received(:get_json).with('/as_arclight/index_versions')
    end

    it 'posts a new index version to the as_arclight backend' do
      allow(JSONModel::HTTP).to receive(:post_form)

      IndexVersion.create_index_version(3, '{"config":"hash"}')

      expect(JSONModel::HTTP).to have_received(:post_form)
                                   .with('/as_arclight/index_version',
                                         :version => 3,
                                         :config_hash => '{"config":"hash"}')
    end
  end

  describe '#generate_index_version_hash' do
    it 'covers the config that would invalidate an existing index' do
      allow(AppConfig).to receive(:[]).with(:as_arclight_resource_id_prefix).and_return('pfx')
      allow(AppConfig).to receive(:[]).with(:as_arclight_archival_object_id_delimiter).and_return('-')

      expect(JSON.parse(IndexVersion.generate_index_version_hash))
        .to eq('as_arclight_resource_id_prefix' => 'pfx',
               'as_arclight_archival_object_id_delimiter' => '-')
    end
  end
end
