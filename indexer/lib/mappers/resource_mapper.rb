class ResourceMapper < ArclightMapper

  def self.resolves
    ['repository', 'linked_agents', 'subjects']
  end

  def repository
    @json['repository']['_resolved']
  end

  # ArcLight needs a value in ead_ssi, but ead_id is not required in ArchivesSapce
  # so use the four part id as a default
  def ead_id
    @json['ead_id'] || [0,1,2,3].map{|n| @json["id_#{n}"]}.select{|i| !i.nil?}.join('-')
  end

  def map
    map_field('id',                     ead_id)
    map_field('title_ssm',              [@json['title']])
    map_field('title_tesim',            [@json['title']])
    map_field('ead_ssi',                ead_id)
    map_field('unitdate_ssm',           @json['dates'].map{|d| format_date(d)})
    map_field('unitdate_inclusive_ssm', @json['dates'].map{|d| format_date(d)})
    map_field('level_ssm',              [@json['level']])
    map_field('level_ssim',             [@json['level'].capitalize])
    map_field('unitid_ssm',             [ead_id]) # FIXME check what is meant to go here
    map_field('unitid_tesim',           [ead_id]) # FIXME and here
    map_field('normalized_date_ssm',    @json['dates'].map{|d| format_date(d)})
    map_field('normalized_title_ssm',   [@json['title'] + ', ' + @map['unitdate_ssm'].join(', ')])
    map_field('collection_title_tesim', [@json['title'] + ', ' + @map['unitdate_ssm'].join(', ')])
    map_field('collection_ssim',        [@json['title'] + ', ' + @map['unitdate_ssm'].join(', ')])
    map_field('repository_ssm',         [repository['name']]) # this has to match the 'name' in arclight's repositories.yml
    map_field('repository_ssim',        [repository['name']])
    map_field('creator_ssm',            @json['linked_agents'].select{|a| a['role'] == 'creator'}.map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('creator_ssim',           @map['creator_ssm'])
    map_field('creator_sort',           @json['linked_agents'].select{|a| a['role'] == 'creator'}.map{|a| a['_resolved']['names'].map{|n| n['sort_name']}}.flatten.uniq)
    map_field('creator_persname_ssim',  @map['creator_ssm'])
    map_field('creators_ssim',          @map['creator_ssm'])

    map_field('access_terms_ssm',       @json['notes'].select{|n| n['type'] == 'userestrict'}
                                                      .map{|n| n['subnotes'].select{|s| s['publish']}
                                                      .map{|s| s['content'].split(/\n+/).map{|c| '<p>' + c + '</p>'}.join("\n") }.join("\n")})

    map_field('access_subjects_ssim',   @json['subjects'].map{|s| s['_resolved']['title']})
    map_field('access_subjects_ssm',    @map['access_subjects_ssim'])
    map_field('has_online_content_ssim',[@json['_online_item_count'] > 0])
    map_field('extent_ssm',             @json['extents'].map{|e| e['container_summary'] || "#{e['number']} #{I18n.t('enumerations.extent_extent_type.' + e['extent_type'])}"})
    map_field('extent_tesim',           @map['extent_ssm'])
    map_field('genreform_ssim',         @json['subjects'].map{|s| s['_resolved']['terms']}.flatten.select{|t| t['term_type'] == 'genre_form'}.map{|t| t['term']})
    map_field('date_range_isim',        @json['dates'].map{|d| (d['begin'][0,4]..(d['end'] || d['begin'])[0,4]).to_a}.flatten.uniq)

    map_field('names_coll_ssim',        @json['linked_agents'].select{|a| a['role'] == 'subject'}.map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('names_ssim',             @json['linked_agents'].map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('corpname_ssim',          @json['linked_agents'].select{|a| a['role'] == 'subject' && a['_resolved']['jsonmodel_type'] == 'agent_corporate_entity'}
                                                              .map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('persname_ssim',          @json['linked_agents'].select{|a| a['role'] == 'subject' && a['_resolved']['jsonmodel_type'] == 'agent_person'}
                                                              .map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('language_ssim',          I18n.t('enumerations.language_iso639_2.' + @json.fetch('finding_aid_language', 'eng')))
    map_field('total_component_count_is',[@json['_total_components']])
    map_field('online_item_count_is',   [@json['_online_item_count']])
    map_field('component_level_isim',   [0])
    map_field('sort_isi',               [0])

    map_notes

    super
  end

end
