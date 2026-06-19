require 'nokogiri'

class EADHelper
  def self.strip_markup(content)
    return if content.nil?
    fragment = Nokogiri::XML.fragment(content)
    fragment.text.strip
  end

  def self.render_paragraph(line)
    fragment = Nokogiri::XML::DocumentFragment.new(Nokogiri::XML::Document.new)

    Nokogiri::XML::Builder.with(fragment) do |xml|
      xml.p { xml << line.strip }
    end

    fragment.to_xml
  end

  def self.render_orderedlist(note)
    fragment = Nokogiri::XML::DocumentFragment.new(Nokogiri::XML::Document.new)

    Nokogiri::XML::Builder.with(fragment) do |xml|
      xml.list(type: 'ordered', numeration: 'arabic') {
        ASUtils.wrap(note['items']).map do |item|
          xml.item { xml << item }
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
            xml.label { xml << item['label'] }
            xml.item { xml << item['value'] }
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
              xml.event { xml << event }
            end
          }
        end
      }
    end

    fragment.to_xml
  end
end