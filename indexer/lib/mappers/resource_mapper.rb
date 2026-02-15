class ResourceMapper < ArclightMapper

  def self.resolves
    ['repository', 'linked_agents', 'subjects']
  end

  def repository
    @json['repository']['_resolved']
  end

  def map
    map_field('id',                     @json['ead_id'])
    map_field('title_ssm',              [@json['title']])
    map_field('title_tesim',            [@json['title']])
    map_field('ead_ssi',                @json['ead_id'])
    map_field('unitdate_ssm',           @json['dates'].map{|d| d['expression']})
    map_field('unitdate_inclusive_ssm', @json['dates'].map{|d| d['expression']})
    map_field('level_ssm',              [@json['level']])
    map_field('level_ssim',             [@json['level'].capitalize])
    map_field('unitid_ssm',             [@json['id_0']])
    map_field('unitid_tesim',           [@json['id_0']])
    map_field('normalized_date_ssm',    @json['dates'].map{|d| d['expression']})
    map_field('normalized_title_ssm',   [@json['title'] + ', ' + @map['unitdate_ssm'].join(', ')])
    map_field('collection_title_tesim', [@json['title'] + ', ' + @map['unitdate_ssm'].join(', ')])
    map_field('collection_ssim',        [@json['title'] + ', ' + @map['unitdate_ssm'].join(', ')])
    map_field('repository_ssm',         [repository['name']])
    map_field('repository_ssim',        [repository['name']])
    map_field('creator_ssm',            @json['linked_agents'].select{|a| a['role'] == 'creator'}.map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('creator_ssim',           @map['creator_ssm'])
    map_field('creator_sort',           @json['linked_agents'].select{|a| a['role'] == 'creator'}.map{|a| a['_resolved']['names'].map{|n| n['sort_name']}}.flatten.uniq)
    map_field('creator_persname_ssim',  @map['creator_ssm'])
    map_field('creators_ssim',          @map['creator_ssm'])
    map_field('access_terms_ssm',       @json['notes'].select{|n| n['type'] == 'userestrict'}.map{|n| n['subnotes'].select{|s| s['publish']}.map{|s| s['content']}.join("\n")})
    map_field('access_subjects_ssim',   @json['subjects'].map{|s| s['_resolved']['title']})
    map_field('access_subjects_ssm',    @map['access_subjects_ssim'])
    map_field('has_online_content_ssim',[false]) # FIXME
    map_field('extent_ssm',             @json['extents'].map{|e| e['container_summary']})
    map_field('extent_tesim',           @map['extent_ssm'])
    map_field('genreform_ssim',         @json['subjects'].map{|s| s['_resolved']['terms']}.flatten.select{|t| t['term_type'] == 'genre_form'}.map{|t| t['term']})
    map_field('date_range_isim',        @json['dates'].map{|d| (d['begin']..d['end']).to_a}.flatten.uniq)
    map_field('accessrestrict_heading_ssm', ['Access Restrictions'])
    map_field('accessrestrict_tesm',    @json['notes'].select{|n| n['type'] == 'accessrestrict'}.map{|n| n['subnotes'].select{|s| s['publish']}.map{|s| s['content']}.join("\n")})
    map_field('accessrestrict_html_tesm',@map['accessrestrict_tesm'].map{|n| '<p>' + n + '</p>'})
    map_field('arrangement_heading_ssm',['Arrangement'])
    map_field('arrangement_tesm',       @json['notes'].select{|n| n['type'] == 'arrangement'}
                                                      .map{|n| n['subnotes']}.flatten
                                                      .select{|s| s['publish']}
                                                      .map{|s| s['items'] ? s['items'].join(', ') : s['content']})
    map_field('arrangement_html_tesm',  @map['arrangement_tesm'].map{|n| '<p>' + n + '</p>'})
    map_field('bioghist_heading_ssm',   ['Historical/Biographical Note'])
    map_field('bioghist_tesm',          @json['notes'].select{|n| n['type'] == 'bioghist'}.map{|n| n['subnotes'].select{|s| s['publish']}.map{|s| s['content']}.join("\n")})
    map_field('bioghist_html_tesm',     @map['bioghist_tesm'].map{|n| '<p>' + n + '</p>'})
    map_field('custodhist_heading_ssm', ['Provenance'])
    map_field('custodhist_tesm',        @json['notes'].select{|n| n['type'] == 'custodhist'}.map{|n| n['subnotes'].select{|s| s['publish']}.map{|s| s['content']}.join("\n")})
    map_field('custodhist_html_tesm',   @map['custodhist_tesm'].map{|n| '<p>' + n + '</p>'})
    map_field('prefercite_tesim',       @json['notes'].select{|n| n['type'] == 'prefercite'}.map{|n| n['subnotes'].select{|s| s['publish']}.map{|s| s['content']}.join("\n")})
    map_field('prefercite_html_tesm',   @map['prefercite_tesim'].map{|n| '<p>' + n + '</p>'})
    map_field('scopecontent_heading_ssm',['Scope and Content Note'])
    map_field('scopecontent_tesm',      @json['notes'].select{|n| n['type'] == 'scopecontent'}.map{|n| n['subnotes'].select{|s| s['publish']}.map{|s| s['content']}.join("\n")})
    map_field('scopecontent_html_tesm', @map['scopecontent_tesm'].map{|n| '<p>' + n + '</p>'})
    map_field('userestrict_heading_ssm',['Use Restrictions'])
    map_field('userestrict_tesm',       @json['notes'].select{|n| n['type'] == 'userestrict'}.map{|n| n['subnotes'].select{|s| s['publish']}.map{|s| s['content']}.join("\n")})
    map_field('userestrict_html_tesm',  @map['userestrict_tesm'].map{|n| '<p>' + n + '</p>'})
    map_field('abstract_tesim',         @json['notes'].select{|n| n['type'] == 'abstract' && n['publish']}.map{|s| s['content'].join("\n")})
    map_field('abstract_html_tesm',     @map['abstract_tesim'].map{|n| '<p>' + n + '</p>'})
    map_field('names_coll_ssim',        @json['linked_agents'].select{|a| a['role'] == 'subject'}.map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('names_ssim',             @json['linked_agents'].map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('corpname_ssim',          @json['linked_agents'].select{|a| a['role'] == 'subject' && a['_resolved']['jsonmodel_type'] == 'agent_corporate_entity'}
                                                              .map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('persname_ssim',          @json['linked_agents'].select{|a| a['role'] == 'subject' && a['_resolved']['jsonmodel_type'] == 'agent_person'}
                                                              .map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('language_ssim',          @json['finding_aid_language'])
    map_field('total_component_count_is',[719]) # FIXME
    map_field('online_item_count_is',   [0]) # FIXME
    map_field('component_level_isim',   [0])
    map_field('sort_isi',               [0])

    super
  end

end
