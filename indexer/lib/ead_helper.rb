require 'nokogiri'

class EADHelper
  def self.strip_markup(content)
    return if content.nil?

    encoded = EADHelper.encode_markup(content)

    fragment = Nokogiri::XML.fragment(encoded)
    fragment.text.strip
  end

  def self.encode_markup(content)
    return if content.nil?

    Nokogiri::HTML.fragment(content).inner_html
  end

  def self.render_paragraph(line)
    fragment = Nokogiri::XML::DocumentFragment.new(Nokogiri::XML::Document.new)

    Nokogiri::XML::Builder.with(fragment) do |xml|
      xml.p { xml << EADHelper.encode_markup(line.strip) }
    end

    fragment.to_xml
  end

  def self.render_orderedlist(note)
    fragment = Nokogiri::XML::DocumentFragment.new(Nokogiri::XML::Document.new)

    Nokogiri::XML::Builder.with(fragment) do |xml|
      xml.list(type: 'ordered', numeration: 'arabic') {
        ASUtils.wrap(note['items']).map do |item|
          xml.item { xml << EADHelper.encode_markup(item) }
        end
      }
    end

    fragment.to_xml
  end

  def self.render_definedlist(note)
    fragment = Nokogiri::XML::DocumentFragment.new(Nokogiri::XML::Document.new)

    Nokogiri::XML::Builder.with(fragment) do |xml|
      xml.list(type: "deflist") {
        ASUtils.wrap(note['items']).map do |item|
          xml.defitem {
            xml.label { xml << EADHelper.encode_markup(item['label']) }
            xml.item { xml << EADHelper.encode_markup(item['value']) }
          }
        end
      }
    end

    fragment.to_xml
  end

  def self.render_chronology(note)
    fragment = Nokogiri::XML::DocumentFragment.new(Nokogiri::XML::Document.new)

    Nokogiri::XML::Builder.with(fragment) do |xml|
      xml.chronlist {
        ASUtils.wrap(note['items']).map do |item|
          xml.chronitem {
            xml.date item['event_date']
            ASUtils.wrap(item['events']).each do |event|
              xml.event { xml << EADHelper.encode_markup(event) }
            end
          }
        end
      }
    end

    fragment.to_xml
  end
end