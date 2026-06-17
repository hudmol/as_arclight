require 'json'

module Arclight

  class Mapper

    require_relative 'resource_mapper'
    require_relative 'archival_object_mapper'

    @resource_mapper = Arclight::ResourceMapper
    @archival_object_mapper = Arclight::ArchivalObjectMapper

    def self.register_resource_mapper(mapper_class)
      unless mapper_class.ancestors.include?(self)
        raise "as_arclight plugin: Custom mapper classes must subclass Arclight::Mapper"
      end

      @resource_mapper = mapper_class
    end

    def self.resource_mapper
      @resource_mapper
    end

    def self.register_archival_object_mapper(mapper_class)
      unless mapper_class.ancestors.include?(self)
        raise "as_arclight plugin: Custom mapper classes must subclass Arclight::Mapper"
      end

      @archival_object_mapper = mapper_class
    end

    def self.archival_object_mapper
      @archival_object_mapper
    end

    def self.resolves
      []
    end

    def initialize(json)
      @json = json
      @map = {}

      self.map
    end

    def map
      raise NotImplementedError, "Arclight Mapper classes must implement #map"
    end

    def doc_id
      @map['id']
    end

    def map_field(field, mapped, &block)
      if block_given?
        @map[field] = block.call
      else
        @map[field] = mapped
      end
    end

    def resource_id(json)
      id = json['ead_id'] || [0,1,2,3].map{|n| json["id_#{n}"]}.select{|i| !i.nil?}.join('-')

      id.tr!('.', '-')

      if AppConfig.has_key?(:as_arclight_resource_id_prefix)
        id = AppConfig[:as_arclight_resource_id_prefix] + id
      end

      id
    end

    def collection_title(json)
      EADToHTML.strip_markup(json['title']) + ', ' + json['dates'].map{|d| format_date(d)}.join(', ')
    end

    SUPPORTED_NOTE_TYPES = [
      'accessrestrict',
      'acqinfo',
      'arrangement',
      'bioghist',
      'custodhist',
      'physloc',
      'prefercite',
      'processinfo',
      'scopecontent',
      'separatedmaterial',
      'userestrict',
      'abstract',
      'odd',
    ]

    MULTIPART_NOTE_TYPES = [
      'note_bioghist',
      'note_general_context',
      'note_legal_status',
      'note_mandate',
      'note_multipart',
      'note_structure_or_genealogy',
    ]

    SINGLEPART_NOTE_TYPES = [
      'note_abstract',
      'note_digital_object',
      'note_langmaterial',
      'note_singlepart',
      'note_text',
    ]

    def map_notes
      SUPPORTED_NOTE_TYPES.each do |note_type|
        notes_to_process = ASUtils.wrap(@json['notes'])
                             .filter{|n| n['type'] == note_type && n['publish']}

        if notes_to_process.length > 0
          map_field("#{note_type}_heading_ssm",  [I18n.t('enumerations._note_types.' + note_type)])

          map_field("#{note_type}_tesm",
                    notes_to_process
                      .map{|n| render_note(n, strip_markup: true)}
                      .flatten
                      .compact)

          map_field("#{note_type}_tesim", @map["#{note_type}_tesm"])

          map_field("#{note_type}_html_tesm",
                    notes_to_process
                      .map{|n| render_note(n)}
                      .flatten
                      .compact)

          if note_type == 'acqinfo'
            map_field("#{note_type}_ssim", @map["#{note_type}_tesim"])
          end
        end
      end
    end

    def render_note(note, opts = {})
      return if !note['publish']

      case note.fetch('jsonmodel_type')
      when *MULTIPART_NOTE_TYPES
        ASUtils.wrap(note['subnotes']).map do |subnote|
          render_note(subnote, opts)
        end.flatten
      when *SINGLEPART_NOTE_TYPES
        ASUtils.wrap(note['content']).map do |note_text|
          render_note_text(note_text.split(/\n+/).map{|c| '<p>' + c + '</p>'}.join("\n"), opts)
        end
      when 'note_orderedlist'
        out = "<ol>\n"
        ASUtils.wrap(note['items']).map do |item|
          out += "<li>#{item}</li>\n"
        end
        out += "</ol>\n"

        render_note_text(out, opts)
      when 'note_definedlist'
        out = "<dl class='deflist'>\n"
        ASUtils.wrap(note['items']).map do |item|
          out += "<dt>#{item['label']}</dt>\n"
          out += "<dd>#{item['value']}</dd>\n"
        end
        out += "</dl>\n"

        render_note_text(out, opts)
      when 'note_chronology'
        out = "<dl class='deflist'>\n"
        ASUtils.wrap(note['items']).map do |item|
          out += "<dt>#{item['event_date']}</dt>\n"
          out += "<dt>#{item['place']}</dt>\n"
          item['events'].each do | event |
            out += "<dd>#{event}</dd>\n"
          end
        end
        out += "</dl>\n"

        render_note_text(out, opts)
      else
        ARCLog.warn("Unrecognised note type: #{note.fetch('jsonmodel_type')}")
        nil
      end
    end

    def render_note_text(note_text, opts = {})
      if opts.fetch(:strip_markup, false)
        EADToHTML.strip_markup(note_text)
      else
        EADToHTML.convert(note_text)
      end
    end

    def find_year_bounds(date)
      if date['begin'] || date['end']
        [date.fetch('begin', date['end'])[0,4], date.fetch('end', date['begin'])[0,4]]
      else
        [nil, nil]
      end
    end

    def format_date(date)
      if date['expression']
        date['expression']
      else
        begin_year, end_year = find_year_bounds(date)
        if begin_year
          [begin_year, end_year].uniq.join('-')
        else
          # this case can't happen - dates need at least one of: expression, begin or end
          ''
        end
      end
    end

    def format_date_range(dates)
      dates.map{|d|
        begin_year, end_year = find_year_bounds(d)
        if begin_year
          (begin_year..end_year).to_a
        else
          nil
        end
      }.flatten.compact.sort.uniq
    end

    def json
      @map.to_json
    end
  end
end
