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
      allow(AppConfig).to receive(:has_key?).and_call_original
      allow(AppConfig).to receive(:has_key?).with(:as_arclight_resource_id_prefix).and_return(true)
      allow(AppConfig).to receive(:[]).and_call_original
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

  describe '#map_notes ordered-list handling' do
    # `arrangement` is configured as an 'orderedlist' note type.
    let(:notes_mapper_class) do
      Class.new(Arclight::Mapper) do
        def map
          map_notes
        end
      end
    end

    it 'maps ordered-list notes built from both item and content subnotes' do
      json = {
        'notes' => [
          {
            'type' => 'arrangement',
            'publish' => true,
            'subnotes' => [
              { 'publish' => true, 'items' => %w[First Second] },
              { 'publish' => true, 'content' => "Para one\nPara two" },
              # a subnote with neither items nor content exercises the empty branch
              { 'publish' => true }
            ]
          }
        ]
      }

      mapper = notes_mapper_class.new(json)
      mapped = JSON.parse(mapper.json)

      expect(mapped['arrangement_tesm']).to include('First, Second')
      expect(mapped['arrangement_tesm']).to include("Para one\nPara two")
      expect(mapped['arrangement_tesim']).to eq(mapped['arrangement_tesm'])

      html = mapped['arrangement_html_tesm'].join("\n")
      expect(html).to include('<list type="ordered">')
      expect(html).to include('<item>First</item>')
      expect(html).to include('<item>Second</item>')
      expect(html).to include('<p>Para one</p>')
    end
  end
end
