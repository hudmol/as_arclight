class IIIFClient

  class Extractors

    class TextExtractor
      def extract(s)
        s
      end
    end

    class HOCRExtractor
      def extract(s)
        doc = Nokogiri::HTML(s)
        doc.css('.ocrx_word').map(&:text).join(' ').gsub(/\s+/, ' ').strip
      end
    end

    class HTMLExtractor
      def extract(s)
        doc = Nokogiri::HTML(s)
        doc.css('body').text.gsub(/\s+/, ' ').strip
      end
    end

  end

end
