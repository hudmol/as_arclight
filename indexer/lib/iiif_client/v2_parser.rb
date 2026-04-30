require_relative 'shared_parser'

class IIIFClient

  class V2Parser

    def version
      2
    end

    def parse_metadata(json)
      result = []

      json.fetch('metadata', []).each do |entry|
        labels = []

        SharedParser.wrap(entry.fetch('label', nil)).each do |label|
          if label.is_a?(String)
            labels << IIIFText.new('unspecified', label)
          else
            labels << IIIFText.new(label.fetch('@language'), label.fetch('@value'))
          end
        end

        SharedParser.wrap(entry.fetch('value', nil)).each do |value|
          labels.each do |label|
            if value.is_a?(String)
              result << IIIFMetadata.new(label, IIIFText.new('unspecified', value))
            else
              result << IIIFMetadata.new(label, IIIFText.new(value.fetch('@language'), value.fetch('@value')))
            end
          end
        end
      end

      result
    end

    def parse_rendering(tree)
      if ['@id', 'format'].all?{|attr| tree[attr]}
        IIIFRendering.from_hash(
          type: tree.fetch('@type', nil),
          format: tree.fetch('format'),
          url: tree.fetch('@id'),
          profile: nil,
          labels: [tree.fetch('label')].compact
        )
      else
        nil
      end
    end

    def possible_rendering?(path_to_root, _tree)
      path_to_root.include?('rendering')
    end

    def possible_annotation?(path_to_root, _tree)
      path_to_root.include?('annotations')
    end

    def parse_annotation(tree)
      SharedParser.parse_annotation(tree)
    end

  end

end
