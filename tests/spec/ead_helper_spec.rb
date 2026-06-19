require 'rspec'
require_relative '../../indexer/lib/ead_helper'

describe EADHelper do
  describe '.strip_markup' do
    it 'returns nil when given nil' do
      expect(EADHelper.strip_markup(nil)).to be_nil
    end

    it 'removes simple tags' do
      expect(EADHelper.strip_markup('<unittitle>Title</unittitle>')).to eq('Title')
    end

    it 'removes nested tags and preserves text' do
      input = '<ead><archdesc><did><unittitle>My Title</unittitle><unitdate>2001</unitdate></did></archdesc></ead>'
      expect(EADHelper.strip_markup(input)).to eq('My Title2001')
    end

    it 'removes tags with attributes' do
      expect(EADHelper.strip_markup('<note type="access">Open</note>')).to eq('Open')
    end

    it 'handles whitespace and newlines' do
      input = "<unittitle>\n  Title with spaces\n</unittitle>\n"
      expect(EADHelper.strip_markup(input)).to eq('Title with spaces')
    end

    it 'preserves CDATA content inside elements' do
      input = '<p><![CDATA[Some <b>bold</b> text]]></p>'
      expect(EADHelper.strip_markup(input)).to eq('Some <b>bold</b> text')
    end

    it 'strips comments and processing instructions' do
      input = '<!--comment--><p>Text<?pi instruction?></p>'
      expect(EADHelper.strip_markup(input)).to eq('Text')
    end
  end

  describe '.render_paragraph' do
    it 'wraps a single line in <p> tags and strips whitespace' do
      expect(EADHelper.render_paragraph("  Hello world  ")).to eq('<p>Hello world</p>')
    end

    it 'renders an empty paragraph for blank lines' do
      expect(EADHelper.render_paragraph("   ")).to eq('<p></p>')
    end
  end

  describe '.render_orderedlist' do
    it 'renders an ordered list with each item wrapped in <item>' do
      note = { 'items' => ['First', 'Second'] }
      expected = "<list type=\"ordered\" numeration=\"arabic\">\n" \
        "<item>First</item>\n" \
        "<item>Second</item>\n" \
        "</list>\n"
      expect(EADHelper.render_orderedlist(note)).to eq(expected)
    end

    it 'handles a single item (non-array) via ASUtils.wrap' do
      note = { 'items' => 'Single' }
      expected = "<list type=\"ordered\" numeration=\"arabic\">\n" \
        "<item>Single</item>\n" \
        "</list>\n"
      expect(EADHelper.render_orderedlist(note)).to eq(expected)
    end
  end

  describe '.render_definedlist' do
    it 'renders a definition list from label/value pairs' do
      note = {
        'items' => [
          { 'label' => 'Label1', 'value' => 'Value1' },
          { 'label' => 'Label2', 'value' => 'Value2' }
        ]
      }

      expected = "<list type=\"deflist\">\n" \
        "<defitem>\n" \
        "<label>Label1</label>\n" \
        "<item>Value1</item>\n" \
        "</defitem>\n" \
        "<defitem>\n" \
        "<label>Label2</label>\n" \
        "<item>Value2</item>\n" \
        "</defitem>\n" \
        "</list>\n"

      expect(EADHelper.render_definedlist(note)).to eq(expected)
    end
  end

  describe '.render_chronology' do
    it 'renders a chronology with date and events' do
      note = {
        'items' => [
          { 'event_date' => '1900', 'events' => ['Born', 'Started school'] },
          { 'event_date' => '1950', 'events' => ['Retired'] }
        ]
      }

      expected = "<chronlist>\n" \
        "<chronitem>\n" \
        "<date>1900</date>\n" \
        "<event>Born</event>\n" \
        "<event>Started school</event>\n" \
        "</chronitem>\n" \
        "<chronitem>\n" \
        "<date>1950</date>\n" \
        "<event>Retired</event>\n" \
        "</chronitem>\n" \
        "</chronlist>\n"

      expect(EADHelper.render_chronology(note)).to eq(expected)
    end
  end
end