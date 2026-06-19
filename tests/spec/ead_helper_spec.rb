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
end