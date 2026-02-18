require 'json'

class ArclightMapper

  def self.resolves
    []
  end

  def initialize(json)
    @json = json
    @map = {}

    self.map
  end

  def map
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

  # FIXME: check for other types - might have been missed in the example
  def map_notes
    {
     'accessrestrict' => 'multipart',
     'arrangement' => 'orderedlist',
     'bioghist' => 'multipart',
     'custodhist' => 'multipart',
     'prefercite' => 'multipart', # FIXME: in example has no header and has _tesim, might need a special type
     'scopecontent' => 'multipart',
     'userestrict' => 'multipart',
     'abstract' => 'singlepart', # FIXME: in example has no header and has _tesim, might need a special type
     'odd' => 'multipart'
    }.each do |note, type|

      if @json['notes'].find{|n| n['type'] == note}
        map_field("#{note}_heading_ssm",  [I18n.t('enumerations._note_types.' + note)])

        if type == 'multipart'
          map_field("#{note}_tesm",
                    @json['notes'].select{|n| n['type'] == note}
                      .map{|n| n['subnotes'].select{|s| s['publish']}
                        .map{|s| s['content']}.join("\n")})

          map_field("#{note}_html_tesm",
                    @map["#{note}_tesm"].map{|n| n.split(/\n+/).map{|s| '<p>' + s + '</p>'}}.flatten)

        elsif type == 'singlepart'
          map_field("#{note}_tesm",
                    @json['notes'].select{|n| n['type'] == note && n['publish']}
                      .map{|s| s['content'].join("\n")})

          map_field("#{note}_html_tesm",
                    @map["#{note}_tesm"].map{|n| '<p>' + n + '</p>'})

        elsif type == 'orderedlist'
          map_field("#{note}_tesm",
                    @json['notes'].select{|n| n['type'] == note}
                      .map{|n| n['subnotes']}.flatten
                      .select{|s| s['publish']}
                      .map{|s| s['items'] ? s['items'].join(', ') : s['content']})

          map_field("#{note}_html_tesm",
                    @json['notes'].select{|n| n['type'] == note}.map{|n|
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
                    })
        end
      end
    end
  end

  def format_date(date)
    date['expression'] || (date['begin'][0,4] + (date['end'] ? "-#{date['end'][0,4]}" : ''))
  end

  def json
    @map.to_json
  end
end
