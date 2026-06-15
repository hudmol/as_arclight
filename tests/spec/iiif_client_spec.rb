require 'json'
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
  end
end
