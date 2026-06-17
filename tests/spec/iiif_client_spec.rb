require 'json'
require 'time'
require_relative '../../indexer/lib/iiif_client'

describe IIIFClient do
  let(:config) { IIIFClient::Config.new }
  let(:client) { IIIFClient.new(config) }

  let(:v3_fixture_path) do
    File.expand_path(File.join(File.dirname(__FILE__), '..', 'fixtures', 'example_v3_iiif_manifest.json'))
  end

  let(:v3_manifest_body) { File.read(v3_fixture_path) }

  let(:v2_fixture_path) do
    File.expand_path(File.join(File.dirname(__FILE__), '..', 'fixtures', 'example_v2_iiif_manifest.json'))
  end

  let(:v2_manifest_body) { File.read(v2_fixture_path) }

  describe '#fetch_manifest' do
    it 'parses a v3 manifest and extracts metadata and renderings' do
      response = IIIFClient::HTTPResponse.new('200', { 'content-type' => ['application/json'] }, v3_manifest_body)
      allow(client).to receive(:fetch_url).and_return(response)

      manifest = client.fetch_manifest('http://example/manifest.json')

      expect(manifest.version).to eq(3)

      # metadata entries should include the resource_type => Document pair from the fixture
      expect(manifest.metadata).to be_an(Array)
      expect(manifest.metadata.any? { |m|
        m.label.is_a?(IIIFClient::IIIFText) &&
        m.label.value == 'resource_type' &&
        m.value.is_a?(IIIFClient::IIIFText) &&
        m.value.value == 'Document'
      }).to be_truthy

      # top-level renderings (content.txt and binder.pdf) should be present
      rendering_urls = manifest.renderings.map { |tree_item| tree_item.item.url }
      expect(rendering_urls.any? { |u| u.include?('content.txt') }).to be_truthy
    end

    it 'parses a v2 manifest and extracts metadata and renderings' do
      response = IIIFClient::HTTPResponse.new('200', { 'content-type' => ['application/json'] }, v2_manifest_body)
      allow(client).to receive(:fetch_url).and_return(response)

      manifest = client.fetch_manifest('http://example/manifest.json')

      expect(manifest.version).to eq(2)

      # metadata entries should include the resource_type => Document pair from the fixture
      expect(manifest.metadata).to be_an(Array)
      expect(manifest.metadata.any? { |m|
        m.label.is_a?(IIIFClient::IIIFText) &&
        m.label.value == 'Author' &&
        m.value.is_a?(IIIFClient::IIIFText) &&
        m.value.value == 'Anne Author'
      }).to be_truthy

      # top-level renderings (content.txt and binder.pdf) should be present
      rendering_urls = manifest.renderings.map { |tree_item| tree_item.item.url }
      expect(rendering_urls.any? { |u| u.include?('content.txt') }).to be_truthy

      # the rendering missing an @id should have been skipped by the parser
      expect(rendering_urls.compact).to eq(rendering_urls)
      expect(rendering_urls).to all(be_a(String))

      # the supplementing annotation in the fixture should be parsed out
      expect(manifest.annotations).to be_an(Array)
      expect(manifest.annotations.size).to eq(1)
      annotation = manifest.annotations.first.item
      expect(annotation).to be_a(IIIFClient::IIIFAnnotation)
      expect(annotation.body.map(&:value)).to eq(['This is the transcribed text of page 1.'])
    end

    it 'raises ManifestParseFailed for a non-JSON content-type' do
      response = IIIFClient::HTTPResponse.new('200', { 'content-type' => ['text/html'] }, '<html></html>')
      allow(client).to receive(:fetch_url).and_return(response)

      expect {
        client.fetch_manifest('http://example/manifest.json')
      }.to raise_error(IIIFClient::Errors::ManifestParseFailed)
    end

    it 'raises ManifestParseFailed for invalid JSON body' do
      response = IIIFClient::HTTPResponse.new('200', { 'content-type' => ['application/json'] }, 'not a json')
      allow(client).to receive(:fetch_url).and_return(response)

      expect {
        client.fetch_manifest('http://example/manifest.json')
      }.to raise_error(IIIFClient::Errors::ManifestParseFailed)
    end

    it 'raises UnknownManifestVersion if manifest context/type cannot be recognized' do
      unknown_body = { '@context' => 'http://example.org/context', 'metadata' => [] }.to_json
      response = IIIFClient::HTTPResponse.new('200', { 'content-type' => ['application/json'] }, unknown_body)
      allow(client).to receive(:fetch_url).and_return(response)

      expect {
        client.fetch_manifest('http://example/manifest.json')
      }.to raise_error(IIIFClient::Errors::UnknownManifestVersion)
    end

    it 'raises an HTTPError whose message names the failing status and url' do
      response = IIIFClient::HTTPResponse.new('404', {}, 'not found')
      allow(client).to receive(:fetch_url).and_return(response)

      expect {
        client.fetch_manifest('http://example/missing.json')
      }.to raise_error(
        IIIFClient::Errors::HTTPError,
        'Unexpected HTTP response (status=404; url=http://example/missing.json)'
      )
    end
  end

  describe '#extract_rendering_text' do
    def rendering(type, format, url)
      IIIFClient::IIIFRendering.from_hash(type: type, format: format, url: url, labels: [], profile: nil)
    end

    it 'extracts the text of a rendering that has a matching extractor' do
      r = rendering('Text', 'text/plain', 'http://example/c.txt')
      response = IIIFClient::HTTPResponse.new('200', { 'content-type' => ['text/plain'] }, 'hello world')
      allow(client).to receive(:fetch_url).with('http://example/c.txt', anything).and_return(response)

      results = []
      client.extract_rendering_text([r]) { |res| results << res }

      expect(results.size).to eq(1)
      expect(results.first.is_success?).to be_truthy
      expect(results.first.rendering).to eq(r)
      expect(results.first.text).to eq('hello world')
      expect(results.first.error).to be_nil
    end

    it 'skips renderings that have no matching extractor' do
      r = rendering('Image', 'image/jpeg', 'http://example/x.jpg')
      allow(client).to receive(:fetch_url)

      results = []
      client.extract_rendering_text([r]) { |res| results << res }

      expect(results).to be_empty
      expect(client).not_to have_received(:fetch_url)
    end

    it 'yields a failure result (with an HTTPError) when a rendering cannot be fetched' do
      r = rendering('Text', 'text/plain', 'http://example/c.txt')
      response = IIIFClient::HTTPResponse.new('500', {}, 'boom')
      allow(client).to receive(:fetch_url).and_return(response)

      results = []
      client.extract_rendering_text([r]) { |res| results << res }

      expect(results.size).to eq(1)
      expect(results.first.is_success?).to be_falsey
      expect(results.first.text).to be_nil
      expect(results.first.error).to be_a(IIIFClient::Errors::HTTPError)
    end

    it 'includes the failing status and rendering url in the failure error message' do
      r = rendering('Text', 'text/plain', 'http://example/c.txt')
      response = IIIFClient::HTTPResponse.new('503', {}, 'boom')
      allow(client).to receive(:fetch_url).and_return(response)

      results = []
      client.extract_rendering_text([r]) { |res| results << res }

      expect(results.first.error.message).to eq(
        'Unexpected HTTP response (status=503; url=http://example/c.txt)'
      )
      # the originating response should still be attached to the error for inspection
      expect(results.first.error.response).to eq(response)
    end

    it 'honors the charset declared in the content-type header' do
      r = rendering('Text', 'text/plain', 'http://example/c.txt')
      response = IIIFClient::HTTPResponse.new('200', { 'content-type' => ['text/plain; charset=ISO-8859-1'] }, "Body")
      allow(client).to receive(:fetch_url).and_return(response)

      results = []
      client.extract_rendering_text([r]) { |res| results << res }

      expect(results.first.text.encoding.name).to eq('ISO-8859-1')
    end
  end

  describe '#fetch_url' do
    before(:each) do
      allow(ARCLog).to receive(:debug)
      allow(ARCLog).to receive(:warn)
      allow(ARCLog).to receive(:error)
    end

    it 'raises MaxRedirectsHit once the redirect budget is exhausted' do
      expect {
        client.send(:fetch_url, 'http://example/x.json', 0)
      }.to raise_error(IIIFClient::Errors::MaxRedirectsHit)
    end

    it 'returns a cached response without making an HTTP request' do
      cached = IIIFClient::HTTPResponse.new('200', { 'content-type' => ['application/json'] }, 'cached-body')
      entry = double('cache_entry', json: cached.to_json)
      cache = double('cache')
      allow(cache).to receive(:get_cache_entry).and_return(entry)
      allow(config).to receive(:request_cache).and_return(cache)

      expect(Net::HTTP).not_to receive(:new)

      result = client.send(:fetch_url, 'http://example/x.json', 5)

      expect(result.status).to eq('200')
      expect(result.body).to eq('cached-body')
    end

    it 'fetches, caches, and returns a successful response' do
      cache = IIIFClient::Cache::NullCache.new
      allow(config).to receive(:request_cache).and_return(cache)

      net_response = double('net_response',
                            code: '200',
                            to_hash: { 'content-type' => ['application/json'] },
                            body: '{"ok":true}')
      fake_http = double('http').as_null_object
      allow(fake_http).to receive(:request).and_return(net_response)
      allow(Net::HTTP).to receive(:new).and_return(fake_http)

      expect(cache).to receive(:insert_response).and_call_original

      result = client.send(:fetch_url, 'https://example/x.json', 5)

      expect(result.status).to eq('200')
      expect(result.body).to eq('{"ok":true}')
    end

    it 'follows a redirect to its destination' do
      allow(config).to receive(:request_cache).and_return(IIIFClient::Cache::NullCache.new)

      redirect = Net::HTTPFound.new('1.1', '302', 'Found')
      redirect['location'] = 'http://example/final.json'
      success = double('net_response',
                       code: '200',
                       to_hash: { 'content-type' => ['application/json'] },
                       body: '{"final":true}')

      fake_http = double('http').as_null_object
      allow(fake_http).to receive(:request).and_return(redirect, success)
      allow(Net::HTTP).to receive(:new).and_return(fake_http)

      result = client.send(:fetch_url, 'http://example/start.json', 5)

      expect(result.status).to eq('200')
      expect(result.body).to eq('{"final":true}')
    end

    it 'returns a 499 response when the request permanently fails' do
      allow(config).to receive(:request_cache).and_return(IIIFClient::Cache::NullCache.new)
      # keep the retry loop short so the test does not actually sleep/back off
      allow(config).to receive(:max_request_retries).and_return(1)

      fake_http = double('http').as_null_object
      allow(fake_http).to receive(:request).and_raise(Errno::ECONNREFUSED)
      allow(Net::HTTP).to receive(:new).and_return(fake_http)

      result = client.send(:fetch_url, 'http://example/x.json', 5)

      expect(result.status).to eq('499')
    end

    it 'warns, backs off, and retries after a transient failure before succeeding' do
      allow(config).to receive(:request_cache).and_return(IIIFClient::Cache::NullCache.new)
      allow(config).to receive(:max_request_retries).and_return(3)

      success = double('net_response',
                       code: '200',
                       to_hash: { 'content-type' => ['application/json'] },
                       body: '{"ok":true}')

      attempts = 0
      fake_http = double('http').as_null_object
      allow(fake_http).to receive(:request) do
        attempts += 1
        raise Errno::ECONNRESET if attempts == 1
        success
      end
      allow(Net::HTTP).to receive(:new).and_return(fake_http)

      # don't actually sleep through the back-off interval
      allow(client).to receive(:sleep)

      result = client.send(:fetch_url, 'http://example/x.json', 5)

      expect(attempts).to eq(2)
      expect(result.status).to eq('200')
      expect(client).to have_received(:sleep).once
      expect(ARCLog).to have_received(:warn).with(/Will retry \(attempt 1 of 3\)/)
    end
  end
end

describe IIIFClient::HTTPResponse do
  describe '#is_success?' do
    it 'is true for a 2xx status' do
      expect(described_class.new('204', {}, '').is_success?).to be_truthy
    end

    it 'is false for non-2xx statuses' do
      expect(described_class.new('404', {}, '').is_success?).to be_falsey
      expect(described_class.new('302', {}, '').is_success?).to be_falsey
    end
  end

  describe '#content_type' do
    it 'returns the first content-type header value' do
      response = described_class.new('200', { 'content-type' => ['application/json', 'text/plain'] }, '')
      expect(response.content_type).to eq('application/json')
    end

    it 'defaults to application/octet-stream when the header is absent' do
      expect(described_class.new('200', {}, '').content_type).to eq('application/octet-stream')
    end
  end

  describe 'JSON round trip' do
    it 'serializes and restores the response, base64-encoding the body' do
      response = described_class.new('200', { 'content-type' => ['application/json'] }, 'raw-body')

      restored = described_class.from_json(response.to_json)

      expect(restored.status).to eq('200')
      expect(restored.headers).to eq('content-type' => ['application/json'])
      expect(restored.body).to eq('raw-body')
    end
  end

  describe '#cache_expiration_time' do
    it 'derives the expiry from a cache-control max-age' do
      response = described_class.new('200', { 'cache-control' => ['max-age=3600'] }, 'b')
      expect(response.cache_expiration_time).to be_within(5).of(Time.now + 3600)
    end

    it 'treats no-store / no-cache as already expired' do
      expect(described_class.new('200', { 'cache-control' => ['no-store'] }, 'b').cache_expiration_time).to be < Time.now
      expect(described_class.new('200', { 'cache-control' => ['no-cache'] }, 'b').cache_expiration_time).to be < Time.now
    end

    it 'prefers max-age over the Expires header' do
      response = described_class.new('200', {
        'cache-control' => ['max-age=100'],
        'expires' => [(Time.now + 9999).httpdate]
      }, 'b')
      expect(response.cache_expiration_time).to be_within(5).of(Time.now + 100)
    end

    it 'falls back to a valid Expires header' do
      expires = (Time.now + 7200).httpdate
      response = described_class.new('200', { 'expires' => [expires] }, 'b')
      expect(response.cache_expiration_time).to be_within(1).of(Time.parse(expires))
    end

    it 'treats an unparseable Expires header as already expired' do
      response = described_class.new('200', { 'expires' => ['definitely not a date'] }, 'b')
      expect(response.cache_expiration_time).to be < Time.now
    end

    it 'is already expired when no caching headers are present' do
      expect(described_class.new('200', {}, 'b').cache_expiration_time).to be < Time.now
    end
  end
end
