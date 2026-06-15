require 'json'
require_relative '../../indexer/lib/iiif_client'

describe IIIFClient::SharedParser do
  describe '.wrap' do
    it 'returns arrays unchanged' do
      expect(described_class.wrap([1, 2])).to eq([1, 2])
    end

    it 'wraps nil as an empty array' do
      expect(described_class.wrap(nil)).to eq([])
    end

    it 'wraps a scalar as a one-element array' do
      expect(described_class.wrap('hi')).to eq(['hi'])
      expect(described_class.wrap({ 'a' => 1 })).to eq([{ 'a' => 1 }])
    end
  end

  describe '.parse_annotation' do
    let(:valid_tree) do
      {
        'id' => 'http://example/annotation/1',
        'type' => 'Annotation',
        'motivation' => 'supplementing',
        'target' => 'http://example/canvas/1',
        'body' => {
          'type' => 'TextualBody',
          'language' => 'en',
          'value' => 'Some transcribed text'
        }
      }
    end

    it 'parses an annotation whose body is a single TextualBody hash' do
      annotation = described_class.parse_annotation(valid_tree)

      expect(annotation).to be_a(IIIFClient::IIIFAnnotation)
      expect(annotation.id).to eq('http://example/annotation/1')
      expect(annotation.type).to eq('Annotation')
      expect(annotation.motivation).to eq('supplementing')
      expect(annotation.target).to eq('http://example/canvas/1')
      expect(annotation.body.size).to eq(1)
      expect(annotation.body.first).to eq(IIIFClient::IIIFText.new('en', 'Some transcribed text'))
    end

    it 'parses an annotation whose body is an array of TextualBodies' do
      tree = valid_tree.merge('body' => [
        { 'type' => 'TextualBody', 'language' => 'en', 'value' => 'English' },
        { 'type' => 'TextualBody', 'language' => 'fr', 'value' => 'Francais' }
      ])

      annotation = described_class.parse_annotation(tree)

      expect(annotation.body).to eq([
        IIIFClient::IIIFText.new('en', 'English'),
        IIIFClient::IIIFText.new('fr', 'Francais')
      ])
    end

    it "defaults the language to 'unknown' when the body omits one" do
      tree = valid_tree.merge('body' => { 'type' => 'TextualBody', 'value' => 'No language given' })

      annotation = described_class.parse_annotation(tree)

      expect(annotation.body.first.language).to eq('unknown')
    end

    it 'ignores non-TextualBody bodies' do
      tree = valid_tree.merge('body' => [
        { 'type' => 'Image', 'id' => 'http://example/image.jpg' },
        { 'type' => 'TextualBody', 'language' => 'en', 'value' => 'kept' }
      ])

      annotation = described_class.parse_annotation(tree)

      expect(annotation.body.map(&:value)).to eq(['kept'])
    end

    it 'returns nil when no usable (TextualBody) body remains' do
      tree = valid_tree.merge('body' => { 'type' => 'Image', 'id' => 'http://example/image.jpg' })

      expect(described_class.parse_annotation(tree)).to be_nil
    end

    it 'returns nil when a required attribute is missing' do
      %w[id type body].each do |attr|
        expect(described_class.parse_annotation(valid_tree.reject { |k, _| k == attr })).to be_nil
      end
    end
  end
end

describe IIIFClient::V2Parser do
  let(:parser) { described_class.new }

  it 'reports version 2' do
    expect(parser.version).to eq(2)
  end

  describe '#parse_metadata' do
    it 'returns an empty array when there is no metadata' do
      expect(parser.parse_metadata({})).to eq([])
    end

    it 'parses simple string label/value pairs' do
      result = parser.parse_metadata('metadata' => [{ 'label' => 'Author', 'value' => 'Anne Author' }])

      expect(result.size).to eq(1)
      expect(result.first.label).to eq(IIIFClient::IIIFText.new('unspecified', 'Author'))
      expect(result.first.value).to eq(IIIFClient::IIIFText.new('unspecified', 'Anne Author'))
    end

    it 'parses language-tagged values against a string label' do
      result = parser.parse_metadata('metadata' => [{
        'label' => 'Published',
        'value' => [
          { '@value' => 'Paris, circa 1400', '@language' => 'en' },
          { '@value' => 'Paris, environ 14eme siecle', '@language' => 'fr' }
        ]
      }])

      expect(result.size).to eq(2)
      expect(result.map { |m| m.label.value }.uniq).to eq(['Published'])
      expect(result.map { |m| [m.value.language, m.value.value] }).to eq([
        ['en', 'Paris, circa 1400'],
        ['fr', 'Paris, environ 14eme siecle']
      ])
    end

    it 'parses a language-tagged label object' do
      result = parser.parse_metadata('metadata' => [{
        'label' => { '@language' => 'en', '@value' => 'Title' },
        'value' => 'Book 1'
      }])

      expect(result.first.label).to eq(IIIFClient::IIIFText.new('en', 'Title'))
      expect(result.first.value).to eq(IIIFClient::IIIFText.new('unspecified', 'Book 1'))
    end

    it 'produces a row for every label/value combination' do
      result = parser.parse_metadata('metadata' => [{
        'label' => %w[L1 L2],
        'value' => %w[V1 V2]
      }])

      pairs = result.map { |m| [m.label.value, m.value.value] }
      expect(pairs).to contain_exactly(['L1', 'V1'], ['L2', 'V1'], ['L1', 'V2'], ['L2', 'V2'])
    end
  end

  describe '#parse_rendering' do
    it 'parses a rendering with an @id and format' do
      rendering = parser.parse_rendering(
        '@id' => 'http://example/content.txt',
        '@type' => 'dctypes:Text',
        'format' => 'text/plain',
        'label' => 'Download as plain text'
      )

      expect(rendering).to be_a(IIIFClient::IIIFRendering)
      expect(rendering.url).to eq('http://example/content.txt')
      expect(rendering.type).to eq('dctypes:Text')
      expect(rendering.format).to eq('text/plain')
      expect(rendering.profile).to be_nil
      expect(rendering.labels).to eq(['Download as plain text'])
    end

    it 'omits a missing label rather than including nil' do
      rendering = parser.parse_rendering('@id' => 'http://example/c.txt', 'format' => 'text/plain')

      expect(rendering.labels).to eq([])
      expect(rendering.type).to be_nil
    end

    it 'returns nil when @id is missing' do
      expect(parser.parse_rendering('format' => 'text/plain')).to be_nil
    end

    it 'returns nil when format is missing' do
      expect(parser.parse_rendering('@id' => 'http://example/c.txt')).to be_nil
    end
  end

  describe 'path predicates' do
    it 'treats a path containing "rendering" as a possible rendering' do
      expect(parser.possible_rendering?(['rendering', 0], {})).to be_truthy
      expect(parser.possible_rendering?(['sequences', 0], {})).to be_falsey
    end

    it 'treats a path containing "annotations" as a possible annotation' do
      expect(parser.possible_annotation?(['annotations', 0], {})).to be_truthy
      expect(parser.possible_annotation?(['otherContent', 0], {})).to be_falsey
    end
  end

  it 'delegates #parse_annotation to SharedParser' do
    tree = {
      'id' => 'http://example/a/1', 'type' => 'Annotation',
      'body' => { 'type' => 'TextualBody', 'language' => 'en', 'value' => 'hi' }
    }
    expect(parser.parse_annotation(tree)).to eq(IIIFClient::SharedParser.parse_annotation(tree))
    expect(parser.parse_annotation(tree)).to be_a(IIIFClient::IIIFAnnotation)
  end
end

describe IIIFClient::Extractors do
  describe IIIFClient::Extractors::TextExtractor do
    it 'returns plain text unchanged' do
      expect(described_class.new.extract("Line one\nLine two")).to eq("Line one\nLine two")
    end
  end

  describe IIIFClient::Extractors::HOCRExtractor do
    it 'joins the text of ocrx_word spans and normalizes whitespace' do
      hocr = <<~HTML
        <html><body>
          <div class="ocr_page">
            <span class="ocr_line">
              <span class="ocrx_word">Hello</span>
              <span class="ocrx_word">  there   </span>
              <span class="ocrx_word">world</span>
            </span>
          </div>
        </body></html>
      HTML

      expect(described_class.new.extract(hocr)).to eq('Hello there world')
    end

    it 'returns an empty string when there are no ocrx_word elements' do
      expect(described_class.new.extract('<html><body><p>nothing</p></body></html>')).to eq('')
    end
  end

  describe IIIFClient::Extractors::ALTOExtractor do
    it 'joins the CONTENT attribute of String elements' do
      alto = <<~XML
        <alto>
          <Layout>
            <Page>
              <TextLine>
                <String CONTENT="The" />
                <String CONTENT="quick" />
                <String CONTENT="fox" />
              </TextLine>
            </Page>
          </Layout>
        </alto>
      XML

      expect(described_class.new.extract(alto)).to eq('The quick fox')
    end

    it 'skips String elements that have no content attribute' do
      alto = '<alto><String CONTENT="kept" /><String /></alto>'
      expect(described_class.new.extract(alto)).to eq('kept')
    end
  end

  describe IIIFClient::Extractors::HTMLExtractor do
    it 'extracts the body text and normalizes whitespace' do
      html = <<~HTML
        <html>
          <head><title>Ignored</title></head>
          <body>
            <h1>Heading</h1>
            <p>Some   paragraph    text.</p>
          </body>
        </html>
      HTML

      expect(described_class.new.extract(html)).to eq('Heading Some paragraph text.')
    end
  end
end

describe IIIFClient::Config do
  let(:config) { described_class.new }

  def rendering(type, format)
    IIIFClient::IIIFRendering.from_hash(type: type, format: format, url: 'http://example/x', labels: [], profile: nil)
  end

  describe '#extractor_for_rendering' do
    it 'selects the plain-text extractor for Text/text/plain' do
      expect(config.extractor_for_rendering(rendering('Text', 'text/plain')))
        .to be_a(IIIFClient::Extractors::TextExtractor)
    end

    it 'selects the HOCR extractor for the hocr format' do
      expect(config.extractor_for_rendering(rendering('Text', 'text/vnd.hocr+html')))
        .to be_a(IIIFClient::Extractors::HOCRExtractor)
    end

    it 'selects the ALTO extractor for alto formats' do
      expect(config.extractor_for_rendering(rendering('Text', 'application/alto+xml')))
        .to be_a(IIIFClient::Extractors::ALTOExtractor)
      expect(config.extractor_for_rendering(rendering('Text', 'application/xml+alto')))
        .to be_a(IIIFClient::Extractors::ALTOExtractor)
    end

    it 'returns nil for an unrecognized format' do
      expect(config.extractor_for_rendering(rendering('Text', 'application/pdf'))).to be_nil
    end

    it 'returns nil for a non-Text type' do
      expect(config.extractor_for_rendering(rendering('Image', 'text/plain'))).to be_nil
    end
  end

  describe '#parser_for_version' do
    it 'returns a V3Parser for version 3' do
      expect(config.parser_for_version(3, {})).to be_a(IIIFClient::V3Parser)
    end

    it 'returns a V2Parser for version 2' do
      expect(config.parser_for_version(2, {})).to be_a(IIIFClient::V2Parser)
    end
  end
end
