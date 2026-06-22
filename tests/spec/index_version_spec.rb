describe 'IndexVersion' do

  let!(:indexer) do
    ArclightIndexer.new(nil, nil, "arclight_indexer_test")
  end

  let(:db) { indexer.instance_variable_get(:@db) }

  before(:each) do
    db[:index_version].delete
  end

  describe '#validate_config_or_die!' do
    it 'creates an initial index version on a first run' do
      allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(1)
      IndexVersion.validate_config_or_die!(db)
      expect(db[:index_version].count).to eq(1)
    end

    it 'recommends a reindex if the index version has increased' do
      allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(1)
      IndexVersion.validate_config_or_die!(db)
      allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(2)
      IndexVersion.validate_config_or_die!(db)
      expect(IndexVersion.reindex_required?).to be_truthy
    end

    it 'dies if the index version has decreased' do
      allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(1)
      IndexVersion.validate_config_or_die!(db)
      allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(0)
      expect{ IndexVersion.validate_config_or_die!(db) }.to raise_error(IndexVersion::ConfigurationError)
    end
  end

end
