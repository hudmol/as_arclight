require_relative 'shared_parser'

class IIIFClient

  class V3Parser

    def version
      3
    end

    def parse_metadata(json)
      result = []

      json.fetch('metadata', []).each do |entry|
        labels = []

        entry.fetch('label', {}).each do |label_language, label_values|
          label_values.each do |label|
            labels << IIIFText.new(label_language, label)
          end
        end

        entry.fetch('value', {}).each do |value_language, values|
          values.each do |value|
            labels.each do |label|
              result << IIIFMetadata.new(label, IIIFText.new(value_language, value))
            end
          end
        end
      end

      result
    end

    def parse_rendering(tree)
      return nil unless ['id', 'type', 'format'].all? {|attr| tree[attr]}

      result = IIIFRendering.from_hash(
        type: tree.fetch('type'),
        format: tree.fetch('format'),
        url: tree.fetch('id'),
        profile: tree.fetch('profile', nil),
        labels: []
      )

      tree.fetch('label', {}).each do |language, labels|
        labels.each do |label|
          result.labels << IIIFText.new(language, label)
        end
      end

      result
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
