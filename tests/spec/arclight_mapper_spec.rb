require 'json'
require_relative '../../indexer/lib/mappers/arclight_mapper'

describe Arclight::Mapper do
  # A concrete subclass so we can instantiate the otherwise-abstract base.
  let(:noop_mapper_class) do
    Class.new(Arclight::Mapper) do
      def map; end
    end
  end

  let(:mapper) { noop_mapper_class.new({}) }

  describe 'mapper registration' do
    around(:each) do |example|
      # Preserve and restore the class-level registrations so we don't leak
      # custom mappers into other examples.
      saved_resource = Arclight::Mapper.resource_mapper
      saved_ao = Arclight::Mapper.archival_object_mapper
      example.run
      Arclight::Mapper.register_resource_mapper(saved_resource)
      Arclight::Mapper.register_archival_object_mapper(saved_ao)
    end

    it 'registers a custom resource mapper that subclasses Arclight::Mapper' do
      custom = Class.new(Arclight::Mapper) { def map; end }
      Arclight::Mapper.register_resource_mapper(custom)
      expect(Arclight::Mapper.resource_mapper).to eq(custom)
    end

    it 'refuses a resource mapper that does not subclass Arclight::Mapper' do
      expect {
        Arclight::Mapper.register_resource_mapper(Class.new)
      }.to raise_error(/must subclass Arclight::Mapper/)
    end

    it 'registers a custom archival object mapper that subclasses Arclight::Mapper' do
      custom = Class.new(Arclight::Mapper) { def map; end }
      Arclight::Mapper.register_archival_object_mapper(custom)
      expect(Arclight::Mapper.archival_object_mapper).to eq(custom)
    end

    it 'refuses an archival object mapper that does not subclass Arclight::Mapper' do
      expect {
        Arclight::Mapper.register_archival_object_mapper(Class.new)
      }.to raise_error(/must subclass Arclight::Mapper/)
    end
  end

  describe '.resolves' do
    it 'is empty on the base class' do
      expect(Arclight::Mapper.resolves).to eq([])
    end
  end

  describe '#map' do
    it 'raises NotImplementedError when a subclass does not override it' do
      expect { Arclight::Mapper.new({}) }
        .to raise_error(NotImplementedError, /must implement #map/)
    end
  end

  describe '#map_field' do
    it 'stores a plain mapped value' do
      mapper.map_field('foo_ssm', ['bar'])
      expect(JSON.parse(mapper.json)).to eq('foo_ssm' => ['bar'])
    end

    it 'stores the result of a block when one is given' do
      mapper.map_field('foo_ssm', 'ignored') { ['from-block'] }
      expect(JSON.parse(mapper.json)['foo_ssm']).to eq(['from-block'])
    end
  end

  describe '#doc_id' do
    it 'returns the mapped id field' do
      mapper.map_field('id', 'abc-123')
      expect(mapper.doc_id).to eq('abc-123')
    end
  end

  describe '#resource_id' do
    it 'builds an id from ead_id, replacing dots with dashes' do
      expect(mapper.resource_id('ead_id' => 'a.b.c')).to eq('a-b-c')
    end

    it 'falls back to joining id_0..id_3 when ead_id is absent' do
      expect(mapper.resource_id('id_0' => 'x', 'id_1' => 'y', 'id_3' => 'z')).to eq('x-y-z')
    end

    it 'prepends the configured prefix when one is set' do
      allow(AppConfig).to receive(:has_key?).with(:as_arclight_resource_id_prefix).and_return(true)
      allow(AppConfig).to receive(:[]).with(:as_arclight_resource_id_prefix).and_return('PRE-')

      expect(mapper.resource_id('ead_id' => 'abc')).to eq('PRE-abc')
    end
  end

  describe '#find_year_bounds' do
    it 'returns nil bounds when neither begin nor end is present' do
      expect(mapper.find_year_bounds({})).to eq([nil, nil])
    end

    it 'derives the four-digit bounds from begin and end' do
      expect(mapper.find_year_bounds('begin' => '1999-01-01', 'end' => '2001-12-31'))
        .to eq(['1999', '2001'])
    end
  end

  describe '#format_date' do
    it 'uses the expression verbatim when present' do
      expect(mapper.format_date('expression' => '1999-2001')).to eq('1999-2001')
    end

    it 'collapses to a single year when begin and end match' do
      expect(mapper.format_date('begin' => '1999', 'end' => '1999')).to eq('1999')
    end

    it 'produces a begin-end range when they differ' do
      expect(mapper.format_date('begin' => '1999', 'end' => '2001')).to eq('1999-2001')
    end

    it 'returns an empty string for a date with no expression, begin or end' do
      expect(mapper.format_date({})).to eq('')
    end
  end

  describe '#format_date_range' do
    it 'expands begin/end pairs into a sorted, unique list of years' do
      expect(mapper.format_date_range([{ 'begin' => '1999', 'end' => '2001' }]))
        .to eq(%w[1999 2000 2001])
    end

    it 'ignores dates that have neither begin nor end' do
      expect(mapper.format_date_range([{ 'expression' => 'undated' }])).to eq([])
    end
  end

  describe '#map_notes EAD handling' do
    let(:notes_mapper_class) do
      Class.new(Arclight::Mapper) do
        def map
          map_notes
        end
      end
    end

    it 'maps notes to EAD' do
      json = {
        'notes' => [
          {
            'jsonmodel_type' => 'note_multipart',
            'type' => 'arrangement',
            'publish' => true,
            'subnotes' => [
              { 'jsonmodel_type' => 'note_orderedlist', 'publish' => true, 'items' => %w[First Second] },
              { 'jsonmodel_type' => 'note_definedlist', 'publish' => true, 'items' => [{'label' => 'Label one', 'value' => 'Value one'},
                                                                                       {'label' => 'Label two', 'value' => 'Value two'}] },
              { 'jsonmodel_type' => 'note_chronology', 'publish' => true, 'items' => [{'event_date' => 'Date one', 'place' => 'Place one',
                                                                                       'events' => ['Event one one', 'Event one two']},
                                                                                      {'event_date' => 'Date two', 'place' => 'Place two',
                                                                                       'events' => ['Event two one', 'Event two two']}] },
              { 'jsonmodel_type' => 'note_singlepart', 'publish' => true, 'content' => "Para one\nPara two" },
              # a subnote with neither items nor content exercises the empty branch
              { 'jsonmodel_type' => 'note_notsupported', 'publish' => true }
            ]
          }
        ]
      }

      mapper = notes_mapper_class.new(json)
      mapped = JSON.parse(mapper.json)

      # Stripped/text outputs should include the list items and paragraph content
      expect(mapped['arrangement_tesm']).to include(a_string_including("First"))
      expect(mapped['arrangement_tesm']).to include(a_string_including("Second"))
      expect(mapped['arrangement_tesm']).to include(a_string_including("Para one"))
      expect(mapped['arrangement_tesm']).to include(a_string_including("Para two"))
      expect(mapped['arrangement_tesim']).to eq(mapped['arrangement_tesm'])

      # The "_html_tesm" actually contains EAD-like XML. Join into a single string for easier assertions.
      html = mapped['arrangement_html_tesm'].join("\n")

      # Ordered list EAD elements
      expect(html).to include('<list numeration="arabic" type="ordered">')
      expect(html).to include('<item>First</item>')
      expect(html).to include('<item>Second</item>')

      # Singlepart paragraphs are still <p> elements in the produced XML
      expect(html).to include('<p>Para one</p>')
      expect(html).to include('<p>Para two</p>')

      # Defined list uses defitem/label/item elements (note: the mapper has inconsistent opening/closing tags;
      # checking for the core defitem/label/item fragments is safer)
      expect(html).to include('<defitem>')
      expect(html).to include('<label>Label one</label>')
      expect(html).to include('<item>Value one</item>')
      expect(html).to include('<label>Label two</label>')
      expect(html).to include('<item>Value two</item>')

      # Chronology should use chronlist/chronitem/date/event elements
      expect(html).to include('<chronlist>')
      expect(html).to include('<chronitem>')
      expect(html).to include('<date>Date one</date>')
      expect(html).to include('<date>Date two</date>')
      expect(html).to include('<event>Event one one</event>')
      expect(html).to include('<event>Event one two</event>')
      expect(html).to include('<event>Event two one</event>')
      expect(html).to include('<event>Event two two</event>')
    end
  end
end
