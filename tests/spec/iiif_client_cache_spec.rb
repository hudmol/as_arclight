require 'tempfile'
require 'time'
require 'tmpdir'

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

    it 'purges expired rows when run_expiration! is called' do
      cache = IIIFClient::Cache::SQLiteCache.new(@db_path, {})
      begin
        uri = URI.parse('http://example/expired.json')
        # max-age = 1 second, so this row will be expired after a short wait
        cache.insert_response(uri, make_response(1, '{"gone":true}'))

        sleep 2

        expect { cache.run_expiration! }.not_to raise_error
        expect(cache.get_cache_entry(uri)).to be_nil
      ensure
        cache.close
      end
    end

  end

  describe 'DiskCache' do

    # Note: 'no-store' means HTTPResponse#cache_expiration_time returns (now - 1),
    # so we can test expiry without sleeping.
    def make_response(cache_control, body = '{"a":1}', status = '200')
      headers = { 'content-type' => ['application/json'] }
      headers['cache-control'] = [cache_control] if cache_control

      IIIFClient::HTTPResponse.new(status, headers, body)
    end

    def read_envelope(cache, uri)
      compressed = File.binread(cache.path_for_uri(uri))

      JSON.parse(IIIFClient::Cache::Utils.decompress(compressed.to_java_bytes))
    end

    around(:each) do |example|
      Dir.mktmpdir('as_arclight_disk_cache_test') do |dir|
        @cache_dir = dir
        example.run
      end
    end

    let(:cache) { IIIFClient::Cache::DiskCache.new(@cache_dir, {}) }
    let(:uri) { URI.parse('http://example/manifest.json') }

    it 'returns nil when nothing has been cached for the URI' do
      expect(cache.get_cache_entry(uri)).to be_nil
    end

    it 'stores and retrieves a cached JSON response' do
      response = make_response('max-age=3600', '{"a":1}')

      entry = cache.insert_response(uri, response)

      expect(entry).to be_a(IIIFClient::Cache::CacheEntry)
      expect(entry.url).to eq(uri.to_s)
      expect(entry.json).to eq(response.to_json)

      fetched = cache.get_cache_entry(uri)

      expect(fetched).to be_a(IIIFClient::Cache::CacheEntry)
      expect(fetched.url).to eq(uri.to_s)
      expect(fetched.json).to eq(response.to_json)
      expect(fetched.request_time).to be_within(60).of(Time.now.to_i)
    end

    it 'stores a gzipped JSON envelope at the path given by path_for_uri' do
      cache.insert_response(uri, make_response('max-age=3600'))

      expect(File.exist?(cache.path_for_uri(uri))).to be_truthy

      envelope = read_envelope(cache, uri)

      expect(envelope.fetch('uri')).to eq(uri.to_s)
      expect(envelope.fetch('timestamp')).to be_within(60).of(Time.now.to_i)
      expect(Integer(envelope.fetch('expiration_time'))).to be > Time.now.to_i
      expect(envelope.fetch('response')).to be_a(String)
    end

    it 'shards cache files across subdirectories of the cache path' do
      path = cache.path_for_uri(uri)

      expect(File.dirname(File.dirname(File.dirname(path)))).to eq(@cache_dir)
      expect(path).to eq(cache.path_for_uri(uri.to_s))
      expect(path).not_to eq(cache.path_for_uri(URI.parse('http://example/other.json')))
    end

    it 'leaves no temporary files behind after an insert' do
      cache.insert_response(uri, make_response('max-age=3600'))

      expect(Dir.glob(File.join(@cache_dir, '**', '*.tmp'))).to be_empty
    end

    it 'produces a cache entry that can be rehydrated by HTTPResponse.from_json' do
      body = "have a snowman ☃"
      response = make_response('max-age=3600', body)

      cache.insert_response(uri, response)

      rehydrated = IIIFClient::HTTPResponse.from_json(cache.get_cache_entry(uri).json)

      expect(rehydrated.status).to eq('200')
      expect(rehydrated.content_type).to eq('application/json')
      expect(rehydrated.body.b).to eq(body.b)
    end

    it 'keeps entries for different URIs separate' do
      other_uri = URI.parse('http://example/other.json')

      cache.insert_response(uri, make_response('max-age=3600', '{"first":true}'))
      cache.insert_response(other_uri, make_response('max-age=3600', '{"second":true}'))

      expect(IIIFClient::HTTPResponse.from_json(cache.get_cache_entry(uri).json).body).to eq('{"first":true}')
      expect(IIIFClient::HTTPResponse.from_json(cache.get_cache_entry(other_uri).json).body).to eq('{"second":true}')
    end

    it 'replaces the entry when the same URI is cached again' do
      cache.insert_response(uri, make_response('max-age=3600', '{"version":1}'))
      cache.insert_response(uri, make_response('max-age=3600', '{"version":2}'))

      expect(IIIFClient::HTTPResponse.from_json(cache.get_cache_entry(uri).json).body).to eq('{"version":2}')
      expect(Dir.glob(File.join(@cache_dir, '**', '*.dat.gz')).length).to eq(1)
    end

    it 'does not return an expired entry, and removes it from disk' do
      cache.insert_response(uri, make_response('no-store'))

      expect(File.exist?(cache.path_for_uri(uri))).to be_truthy

      expect(cache.get_cache_entry(uri)).to be_nil
      expect(File.exist?(cache.path_for_uri(uri))).to be_falsey
    end

    it 'respects min_cache_seconds to extend expiration' do
      cache = IIIFClient::Cache::DiskCache.new(@cache_dir, { :min_cache_seconds => 3600 })

      cache.insert_response(uri, make_response('no-store'))

      expect(cache.get_cache_entry(uri)).not_to be_nil
      expect(Integer(read_envelope(cache, uri).fetch('expiration_time'))).to be_within(120).of(Time.now.to_i + 3600)
    end

    it 'does not shorten an expiration that is already beyond min_cache_seconds' do
      cache = IIIFClient::Cache::DiskCache.new(@cache_dir, { :min_cache_seconds => 60 })

      cache.insert_response(uri, make_response('max-age=86400'))

      expect(Integer(read_envelope(cache, uri).fetch('expiration_time'))).to be_within(120).of(Time.now.to_i + 86400)
    end

    it 'discards and deletes a cache file that is not gzipped' do
      cache.insert_response(uri, make_response('max-age=3600'))

      File.binwrite(cache.path_for_uri(uri), 'this is not a gzip stream')

      expect(cache.get_cache_entry(uri)).to be_nil
      expect(File.exist?(cache.path_for_uri(uri))).to be_falsey
    end

    it 'returns nil rather than raising when a cache file holds a truncated gzip stream' do
      cache.insert_response(uri, make_response('max-age=3600'))

      valid_gzip = String.from_java_bytes(IIIFClient::Cache::Utils.compress('{"a":1}'))
      File.binwrite(cache.path_for_uri(uri), valid_gzip[0...10])

      entry = nil
      expect { entry = cache.get_cache_entry(uri) }.not_to raise_error
      expect(entry).to be_nil
    end

    it 'returns nil rather than raising when a cache file is empty' do
      cache.insert_response(uri, make_response('max-age=3600'))

      File.binwrite(cache.path_for_uri(uri), '')

      entry = nil
      expect { entry = cache.get_cache_entry(uri) }.not_to raise_error
      expect(entry).to be_nil
    end

    it 'returns nil rather than raising when a cache file holds gzipped non-JSON' do
      cache.insert_response(uri, make_response('max-age=3600'))

      File.binwrite(cache.path_for_uri(uri),
                    String.from_java_bytes(IIIFClient::Cache::Utils.compress('not json at all')))

      entry = nil
      expect { entry = cache.get_cache_entry(uri) }.not_to raise_error
      expect(entry).to be_nil
    end

    it 'creates its cache directory on demand' do
      cache = IIIFClient::Cache::DiskCache.new(File.join(@cache_dir, 'does', 'not', 'exist', 'yet'), {})

      expect { cache.insert_response(uri, make_response('max-age=3600')) }.not_to raise_error
      expect(cache.get_cache_entry(uri)).not_to be_nil
    end

    it 'supports flush as a no-op' do
      expect { cache.flush }.not_to raise_error
    end
  end
end
