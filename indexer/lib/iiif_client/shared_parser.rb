class IIIFClient

  class SharedParser

    def self.wrap(v)
      if v.is_a?(Array)
        v
      elsif v.nil?
        []
      else
        [v]
      end
    end

    # This is currently the same for V3 and V2
    def self.parse_annotation(tree)
      return nil unless ['id', 'type', 'body'].all? {|attr| tree[attr]}

      annotation = IIIFAnnotation.from_hash(
        id: tree.fetch('id', nil),
        type: tree.fetch('type'),
        motivation: tree.fetch('motivation', nil),
        target: tree.fetch('target', nil),
        body: [],
      )

      wrap(tree.fetch('body', nil)).each do |body|
        if body.fetch('type', '') == 'TextualBody'
          language = body.fetch('language', 'unknown')
          annotation.body << IIIFText.new(language, body.fetch('value'))
        end
      end

      return nil if annotation.body.empty?

      annotation
    end

  end

end
