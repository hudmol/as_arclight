require 'tmpdir'

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

  describe '#validate_config_or_die!' do
    let(:arcdb) { ARCDB.new(Dir.tmpdir) }

    before(:each) do
      arcdb.with_session do
        arcdb.transaction do |db|
          db[:index_version].delete
        end
      end
    end

    it 'creates an initial index version on a first run' do
      arcdb.with_session do
        arcdb.transaction do |db|
          allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(1)
          IndexVersion.validate_config_or_die!(db)
          expect(db[:index_version].count).to eq(1)
        end
      end
    end

    it 'recommends a reindex if the index version has increased' do
      arcdb.with_session do
        arcdb.transaction do |db|
          allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(1)
          IndexVersion.validate_config_or_die!(db)
          allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(2)
          IndexVersion.validate_config_or_die!(db)
          expect(IndexVersion.reindex_required?).to be_truthy
        end
      end
    end

    it 'dies if the index version has decreased' do
      arcdb.with_session do
        arcdb.transaction do |db|
          allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(1)
          IndexVersion.validate_config_or_die!(db)
          allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(0)
          expect{ IndexVersion.validate_config_or_die!(db) }.to raise_error(IndexVersion::ConfigurationError)
        end
      end
    end

    it 'dies if the config has changed but the version has not' do
      arcdb.with_session do
        arcdb.transaction do |db|
          allow(AppConfig).to receive(:[]).with(:as_arclight_index_version).and_return(1)
          IndexVersion.validate_config_or_die!(db)
          allow(AppConfig).to receive(:[]).with(:as_arclight_resource_id_prefix).and_return('new prefix')
          expect{ IndexVersion.validate_config_or_die!(db) }.to raise_error(IndexVersion::ConfigurationError)
        end
      end
    end
  end

end
