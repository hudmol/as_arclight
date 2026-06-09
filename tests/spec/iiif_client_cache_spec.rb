require 'tempfile'
require 'time'

require_relative '../../indexer/lib/iiif_client'

describe IIIFClient::Cache do
  describe 'NullCache' do
    let(:cache) { IIIFClient::Cache::NullCache.new }

    it 'returns nil for get_cache_entry' do
      expect(cache.get_cache_entry(URI.parse('http://example/'))).to be_nil
    end

    it 'allows insert_response without error' do
      response = IIIFClient::HTTPResponse.new('200', { 'content-type' => ['application/json'] }, '{}')
      expect { cache.insert_response(URI.parse('http://example/'), response) }.not_to raise_error
    end
  end

  describe 'SQLiteCache' do
    # Helper to build an HTTPResponse with cache-control max-age header
    def make_response(max_age_seconds, body = 'body', status = '200')
      headers = { 'content-type' => ['application/json'] }
      if max_age_seconds
        headers['cache-control'] = ["max-age=#{max_age_seconds}"]
      end
      IIIFClient::HTTPResponse.new(status, headers, body)
    end

    before(:each) do
      # Create a temp file path for the sqlite DB (delete the tempfile, keep path)
      tf = Tempfile.new('iiif_cache_test_db')
      @db_path = tf.path
      tf.close!
    end

    after(:each) do
      # Ensure DB file removed if present
      begin
        File.delete(@db_path) if @db_path && File.exist?(@db_path)
      rescue
      end
    end

    it 'stores and retrieves a cached JSON response' do
      cache = IIIFClient::Cache::SQLiteCache.new(@db_path, {})
      begin
        uri = URI.parse('http://example/manifest.json')
        response = make_response(3600, '{"a":1}', '200')

        entry = cache.insert_response(uri, response)

        expect(entry).to be_a(IIIFClient::Cache::CacheEntry)
        expect(entry.url).to eq(uri.to_s)
        expect(entry.json).to be_a(String)
        expect(entry.json).to eq(response.to_json)

        fetched = cache.get_cache_entry(uri)
        expect(fetched).to be_a(IIIFClient::Cache::CacheEntry)
        expect(fetched.url).to eq(uri.to_s)
        expect(fetched.json).to eq(response.to_json)
      ensure
        cache.close
      end
    end

    it 'does not return an expired entry' do
      cache = IIIFClient::Cache::SQLiteCache.new(@db_path, {})
      begin
        uri = URI.parse('http://example/short.json')
        # max-age = 1 second
        response = make_response(1, '{"short":true}', '200')

        cache.insert_response(uri, response)

        # Immediately we should get it
        expect(cache.get_cache_entry(uri)).not_to be_nil

        # Wait until it expires
        sleep 2

        expect(cache.get_cache_entry(uri)).to be_nil
      ensure
        cache.close
      end
    end

    it 'respects min_cache_seconds to extend expiration' do
      # min_cache_seconds = 5 sec
      cache = IIIFClient::Cache::SQLiteCache.new(@db_path, { :min_cache_seconds => 5 })
      begin
        uri = URI.parse('http://example/min.json')
        # manifest suggests max-age = 1 second, but min_cache_seconds should extend it
        response = make_response(1, '{"min":true}', '200')

        cache.insert_response(uri, response)

        # Wait 2 seconds - without min_cache_seconds the entry would be expired.
        sleep 2

        # Because min_cache_seconds was 5, the entry should still be present
        expect(cache.get_cache_entry(uri)).not_to be_nil
      ensure
        cache.close
      end
    end
  end
end