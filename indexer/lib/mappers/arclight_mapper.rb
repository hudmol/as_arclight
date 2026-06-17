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

    # FIXME: refactor?
    def map_notes
      {
        'accessrestrict' => 'multipart',
        'acqinfo' => 'multipart',
        'arrangement' => 'orderedlist',
        'bioghist' => 'multipart',
        'custodhist' => 'multipart',
        'physloc' => 'singlepart',
        'prefercite' => 'multipart',
        'processinfo' => 'multipart',
        'scopecontent' => 'multipart',
        'separatedmaterial' => 'multipart',
        'userestrict' => 'multipart',
        'abstract' => 'singlepart',
        'odd' => 'multipart'
      }.each do |note, type|

        if ASUtils.wrap(@json['notes']).find{|n| n['type'] == note && n['publish']}
          map_field("#{note}_heading_ssm",  [I18n.t('enumerations._note_types.' + note)])

          if type == 'multipart'
            map_field("#{note}_tesm",
                      @json['notes']
                        .select{|n| n['type'] == note && n['publish']}
                        .map{|n| n['subnotes']
                                   .select{|s| s['publish']}
                                   .map{|s| s['content']}.join("\n")}
                        .map{|s| EADToHTML.convert(s)})

            map_field("#{note}_tesim", @map["#{note}_tesm"])

            map_field("#{note}_html_tesm",
                      @map["#{note}_tesm"].map{|n| n.split(/\n+/)}.flatten)

            if note == 'acqinfo'
              map_field("#{note}_ssim", @map["#{note}_tesim"])
            end

          elsif type == 'singlepart'
            suffix = note == 'abstract' ? 'tesim' : 'tesm'

            map_field("#{note}_#{suffix}",
                      @json['notes']
                        .select{|n| n['type'] == note && n['publish']}
                        .map{|s| s['content'].join("\n")}
                        .map{|s| EADToHTML.strip_markup(s)})

            map_field("#{note}_html_tesm",
                      @json['notes']
                        .select{|n| n['type'] == note && n['publish']}
                        .map{|s| s['content'].join("\n")}
                        .map{|n| '<p>' + n + '</p>'}
                        .map{|s| EADToHTML.convert(s)})

          elsif type == 'orderedlist'
            map_field("#{note}_tesm",
                      @json['notes']
                        .select{|n| n['type'] == note && n['publish']}
                        .map{|n| n['subnotes']}.flatten
                        .select{|s| s['publish']}
                        .map{|s| s['items'] ? s['items'].join(', ') : s['content']}
                        .map{|s| EADToHTML.strip_markup(s)})

            map_field("#{note}_tesim", @map["#{note}_tesm"])

            map_field("#{note}_html_tesm",
                      @json['notes']
                        .select{|n| n['type'] == note && n['publish']}.map{|n|
                          n['subnotes'].select{|s| s['publish']}.map{|psn|
                            if psn.has_key?('content')
                              psn['content'].split(/\n+/).map{|c| '<p>' + c + '</p>'}.join("\n")
                            elsif psn.has_key?('items')
                              '<list type="ordered">' + "\n" +
                                psn['items'].map{|i| '<item>' + i + '</item>'}.join("\n") +
                                '</list>'
                            else
                              ''
                            end
                          }.join("\n")
                        }.map{|s| EADToHTML.convert(s)})
          end
        end
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
