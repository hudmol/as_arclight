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
      EADHelper.strip_markup(json['title']) + ', ' + json['dates'].map{|d| format_date(d)}.join(', ')
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
                      .map{|note| render_note(note)}
                      .flatten
                      .map{|ead| EADHelper.strip_markup(ead)}
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

    def render_note(note)
      return if !note['publish']

      case note.fetch('jsonmodel_type')
      when *MULTIPART_NOTE_TYPES
        ASUtils.wrap(note['subnotes']).map do |subnote|
          render_note(subnote)
        end.flatten
      when *SINGLEPART_NOTE_TYPES
        ASUtils.wrap(note['content']).map do |note_text|
          note_text
            .split(/\n+/)
            .map{|line| EADHelper.render_paragraph(line)}
        end.flatten
      when 'note_orderedlist'
        EADHelper.render_orderedlist(note)
      when 'note_definedlist'
        EADHelper.render_definedlist(note)
      when 'note_chronology'
        EADHelper.render_chronology(note)
      else
        ARCLog.warn("Unrecognised note type: #{note.fetch('jsonmodel_type')}")
        nil
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
      result = if date['expression']
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

      # Bulk dates get prefixed with the "bulk" label
      if date['date_type'] == 'bulk'
        [I18n.t("date_type_bulk.bulk"), result].join(' ')
      else
        result
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
