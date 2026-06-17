require 'rspec'
require_relative '../../indexer/lib/ead_helper'

describe EADHelper do
  describe '.convert' do
    it 'returns nil for nil content' do
      expect(EADHelper.to_html(nil)).to be_nil
    end

    it 'returns empty string for empty or whitespace content' do
      expect(EADHelper.to_html('')).to eq('')
      expect(EADHelper.to_html('   ')).to eq('')
      expect(EADHelper.to_html("\n")).to eq('')
    end

    context 'basic tag mappings' do
      it 'converts render="italic" to <i>' do
        expect(EADHelper.to_html('<emph render="italic">em</emph>')).to eq('<i>em</i>')
        expect(EADHelper.to_html('<title render="italic">t</title>')).to eq('<i>t</i>')
        expect(EADHelper.to_html('<titleproper render="italic">tp</titleproper>')).to eq('<i>tp</i>')
      end

      it 'converts render="bold", "bolddoublequote", "boldsinglequote" to <b>' do
        expect(EADHelper.to_html('<emph render="bold">b</emph>')).to eq('<b>b</b>')
        expect(EADHelper.to_html('<emph render="bolddoublequote">bdq</emph>')).to eq('<b>bdq</b>')
        expect(EADHelper.to_html('<emph render="boldsinglequote">bsq</emph>')).to eq('<b>bsq</b>')
      end

      it 'converts unknown but listed render values to <span>' do
        expect(EADHelper.to_html('<emph render="altrender">a</emph>')).to include('<span')
        expect(EADHelper.to_html('<emph render="doublequote">dq</emph>')).to include('<span')
        expect(EADHelper.to_html('<title render="nonproport">np</title>')).to include('<span')
      end

      it 'leaves elements without render attribute unchanged' do
        expect(EADHelper.to_html('<emph>plain</emph>')).to eq('<emph>plain</emph>')
        expect(EADHelper.to_html('<title>plain</title>')).to eq('<title>plain</title>')
      end
    end

    context 'style-producing render values' do
      it 'converts render="bolditalic" to <span> and appends bold+italic styles' do
        result = EADHelper.to_html('<emph render="bolditalic">BI</emph>')
        expect(result).to include('<span')
        expect(result).to include('font-weight: bold')
        expect(result).to include('font-style: italic')
        expect(result).not_to include('render=')
      end

      it 'converts render="boldsmcaps" to <span> and appends bold+small-caps styles' do
        result = EADHelper.to_html('<emph render="boldsmcaps">BS</emph>')
        expect(result).to include('<span')
        expect(result).to include('font-weight: bold')
        expect(result).to include('font-variant: small-caps')
        expect(result).not_to include('render=')
      end

      it 'converts render="boldunderline" to <span> and appends underline style' do
        result = EADHelper.to_html('<emph render="boldunderline">BU</emph>')
        expect(result).to include('<span')
        expect(result).to include('text-decoration: underline')
        expect(result).to include('font-weight: bold')
      end

      it 'converts render="smcaps" to <span> with small-caps style' do
        result = EADHelper.to_html('<emph render="smcaps">SC</emph>')
        expect(result).to include('<span')
        expect(result).to include('font-variant: small-caps')
      end

      it 'converts render="sub" and "super" to <span> with vertical-align and smaller font-size' do
        sub_result = EADHelper.to_html('<emph render="sub">sub</emph>')
        super_result = EADHelper.to_html('<emph render="super">sup</emph>')

        expect(sub_result).to include('vertical-align: sub')
        expect(sub_result).to include('font-size: smaller')
        expect(super_result).to include('vertical-align: super')
        expect(super_result).to include('font-size: smaller')
      end

      it 'converts render="underline" to <span> with text-decoration: underline' do
        result = EADHelper.to_html('<emph render="underline">u</emph>')
        expect(result).to include('text-decoration: underline')
      end
    end

    context 'style accumulation behavior' do
      it 'adds styles with a separator when existing style does not end with semicolon' do
        result = EADHelper.to_html('<emph render="bolditalic" style="color: red">X</emph>')
        # Expect a separator "; " between existing style and appended styles
        expect(result).to include('style="color: red; font-weight: bold; font-style: italic;"')
      end

      it 'appends styles without extra separator when existing style ends with semicolon' do
        result = EADHelper.to_html('<emph render="bolditalic" style="color: red;">X</emph>')
        # When existing style ends with semicolon, implementation does not add an extra separator;
        # so the result will concatenate directly. Check for the exact behavior (no added space)
        expect(result).to include('style="color: red;font-weight: bold; font-style: italic;"')
      end
    end

    context 'multiple and nested elements' do
      it 'converts several elements within a fragment' do
        content = 'Start <emph render="italic">I</emph> middle <emph render="bold">B</emph> end'
        result = EADHelper.to_html(content)
        expect(result).to include('<i>I</i>')
        expect(result).to include('<b>B</b>')
        expect(result).to include('Start')
        expect(result).to include('end')
      end

      it 'handles nested emphasis' do
        result = EADHelper.to_html('<emph render="bold"><emph render="italic">inner</emph></emph>')
        expect(result).to include('<b>')
        expect(result).to include('inner')
        expect(result).to include('</b>')
      end
    end
  end

  describe 'RENDER_ATTRIBUTE_VALUES constant' do
    it 'contains the expected values' do
      expect(EADHelper::RENDER_ATTRIBUTE_VALUES).to include('bold', 'italic', 'bolditalic', 'smcaps', 'sub', 'super', 'underline')
    end
  end
end