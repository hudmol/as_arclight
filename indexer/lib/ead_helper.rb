class EADHelper
  RENDER_ATTRIBUTE_VALUES = [ 'altrender', 'bold', 'bolddoublequote', 'bolditalic', 'boldsinglequote', 'boldsmcaps', 'boldunderline', 'doublequote', 'italic', 'nonproport', 'singlequote', 'smcaps', 'sub', 'super', 'underline']

  def self.strip_markup(content)
    return if content.nil?

    content.gsub(/<.+?>/, '')
  end

  def self.to_html(content)
    return if content.nil?

    content.strip!
    content.chomp!

    return '' if content.empty?

    fragment = Nokogiri::XML::DocumentFragment.parse(content)

    fragment.css('emph, title, titleproper').each do |element|
      if RENDER_ATTRIBUTE_VALUES.include?(element['render'])
        case element['render']
        when 'italic'
          element.name = 'i'
        when 'bold', 'bolddoublequote', 'boldsinglequote'
          element.name = 'b'
        when 'bolditalic'
          element.name = 'span'
          append_styles(element, 'font-weight: bold; font-style: italic;')
        when 'boldsmcaps'
          element.name = 'span'
          append_styles(element, 'font-weight: bold; font-variant: small-caps;')
        when 'boldunderline'
          element.name = 'span'
          append_styles(element, 'font-weight: bold; text-decoration: underline;')
        when 'smcaps'
          element.name = 'span'
          append_styles(element, 'font-variant: small-caps;')
        when 'sub'
          element.name = 'span'
          append_styles(element, 'vertical-align: sub; font-size: smaller;')
        when 'super'
          element.name = 'span'
          append_styles(element, 'vertical-align: super; font-size: smaller;')
        when 'underline'
          element.name = 'span'
          append_styles(element, 'text-decoration: underline;')
        else
          element.name = 'span'
        end

        element.delete('render')
      end
    end

    fragment.to_s
  end

  private

  def self.append_styles(element, styles)
    element['style'] ||= ''
    element['style'] += '; ' unless element['style'].empty? || element['style'].strip.end_with?(';')
    element['style'] += styles
  end
end