require 'nokogiri'

class EADHelper
  def self.strip_markup(content)
    return if content.nil?
    fragment = Nokogiri::XML.fragment(content)
    fragment.text.strip
  end

  def self.render_paragraph(line)
    '<p>' + line.strip + '</p>'
  end

  def self.render_orderedlist(note)
    out = "<list type=\"ordered\" numeration=\"arabic\">\n"
    ASUtils.wrap(note['items']).map do |item|
      out += "<item>#{item}</item>\n"
    end
    out += "</list>\n"
    out
  end

  def self.render_definedlist(note)
    out = "<list type=\"deflist\">\n"
    ASUtils.wrap(note['items']).map do |item|
      out += "<defitem>\n"
      out += "<label>#{item['label']}</label>\n"
      out += "<item>#{item['value']}</item>\n"
      out += "</defitem>\n"
    end
    out += "</list>\n"
    out
  end

  def self.render_chronology(note)
    out = "<chronlist>\n"
    ASUtils.wrap(note['items']).map do |item|
      out += "<chronitem>\n"
      out += "<date>#{item['event_date']}</date>\n"
      ASUtils.wrap(item['events']).each do | event |
        out += "<event>#{event}</event>\n"
      end
      out += "</chronitem>\n"
    end
    out += "</chronlist>\n"
    out
  end
end