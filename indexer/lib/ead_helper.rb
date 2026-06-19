require 'nokogiri'

class EADHelper
  def self.strip_markup(content)
    return if content.nil?
    fragment = Nokogiri::XML.fragment(content)
    fragment.text.strip
  end
end