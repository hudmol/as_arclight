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
      expect(EADHelper.render_paragraph("   ")).to eq('<p/>')
    end

    it 'retains embedded <emph> elements' do
      expect(EADHelper.render_paragraph('I am <emph render="bold">bold</emph> text')).to eq('<p>I am <emph render="bold">bold</emph> text</p>')
    end
  end

  describe '.render_orderedlist' do
    it 'renders an ordered list with each item wrapped in <item>' do
      note = { 'items' => ['First', 'Second'] }
      expected = "<list numeration=\"arabic\" type=\"ordered\">" \
        "<item>First</item>" \
        "<item>Second</item>" \
        "</list>"
      expect(EADHelper.render_orderedlist(note)).to eq(expected)
    end

    it 'handles a single item (non-array) via ASUtils.wrap' do
      note = { 'items' => 'Single' }
      expected = "<list numeration=\"arabic\" type=\"ordered\">" \
        "<item>Single</item>" \
        "</list>"
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

      expected = "<list type=\"deflist\">" \
        "<defitem>" \
        "<label>Label1</label>" \
        "<item>Value1</item>" \
        "</defitem>" \
        "<defitem>" \
        "<label>Label2</label>" \
        "<item>Value2</item>" \
        "</defitem>" \
        "</list>"

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

      expected = "<chronlist>" \
        "<chronitem>" \
        "<date>1900</date>" \
        "<event>Born</event>" \
        "<event>Started school</event>" \
        "</chronitem>" \
        "<chronitem>" \
        "<date>1950</date>" \
        "<event>Retired</event>" \
        "</chronitem>" \
        "</chronlist>"

      expect(EADHelper.render_chronology(note)).to eq(expected)
    end
  end

  describe '.encode_markup' do
    it 'encodes bare ampersands in plain text' do
      expect(EADHelper.encode_markup('rock & roll')).to eq('rock &amp; roll')
    end

    it 'does not double-encode already encoded ampersands' do
      expect(EADHelper.encode_markup('rock &amp; roll')).to eq('rock &amp; roll')
    end

    it 'leaves literal quotes unchanged in plain text' do
      expect(EADHelper.encode_markup('rock "and" roll')).to eq('rock "and" roll')
    end

    it 'preserves encoded quote entities in plain text' do
      expect(EADHelper.encode_markup('rock &quot;and&quot; roll')).to eq('rock "and" roll')
    end

    it 'preserves markup and encoded entities inside attribute values' do
      input = '<emph class="it&quot;a&quot;lic">emphasis</emph>'
      expect(EADHelper.encode_markup(input)).to eq('<emph class="it%22a%22lic">emphasis</emph>')
    end

    it 'preserves encoded less-than entity' do
      expect(EADHelper.encode_markup('4 &lt; 5')).to eq('4 &lt; 5')
    end

    it 'encodes bare ampersands in plain text (One & two)' do
      expect(EADHelper.encode_markup('One & two')).to eq('One &amp; two')
    end

    it 'normalizes mixed encoded and unencoded ampersands' do
      expect(EADHelper.encode_markup('One &amp; two & three')).to eq('One &amp; two &amp; three')
    end

    it 'preserves XML markup while encoding ampersands in text nodes' do
      input = '<em>One &amp; two & three</em><p>A & B</p>'
      expect(EADHelper.encode_markup(input)).to eq('<em>One &amp; two &amp; three</em><p>A &amp; B</p>')
    end

    it 'does not double-encode already-encoded ampersands (Already &amp; encoded)' do
      expect(EADHelper.encode_markup('Already &amp; encoded')).to eq('Already &amp; encoded')
    end

    it 'handles ampersands in element text adjacent to child elements' do
      input = '<p>Rock & roll <em>R&amp;B & soul</em> jazz & blues</p>'
      expect(EADHelper.encode_markup(input)).to eq('<p>Rock &amp; roll <em>R&amp;B &amp; soul</em> jazz &amp; blues</p>')
    end
  end

  describe "encoding" do
    describe "#render_paragraph" do
      cases = {
        "rock & roll" => "<p>rock &amp; roll</p>",
        "rock &amp; roll" => "<p>rock &amp; roll</p>",
        'rock "and" roll' => '<p>rock "and" roll</p>',
        "rock &quot;and&quot; roll" => '<p>rock "and" roll</p>',
        '<emph class="it&quot;a&quot;lic">emphasis</emph>' => '<p><emph class="it%22a%22lic">emphasis</emph></p>',
        '4 &lt; 5' => '<p>4 &lt; 5</p>',
        'One &amp; two & three' => '<p>One &amp; two &amp; three</p>',
        "<emph render=\"bold\">One &amp; two & three</emph>" => '<p><emph render="bold">One &amp; two &amp; three</emph></p>',
        'Rock & roll <emph render="bold">R&amp;B & soul</emph> jazz & blues' => '<p>Rock &amp; roll <emph render="bold">R&amp;B &amp; soul</emph> jazz &amp; blues</p>'
      }

      cases.each do |input, expected_text|
        it "handles #{input.inspect}" do
          rendered = EADHelper.render_paragraph(input)

          expect(rendered).to include(expected_text)
        end
      end
    end
  end
end