class Arclight::ResourceMapper < Arclight::Mapper

  def self.resolves
    ['repository', 'linked_agents', 'subjects']
  end

  def repository
    @json['repository']['_resolved']
  end

  def map
    map_field('id',                     resource_id(@json))
    map_field('archivesspace_uri_ssi',  @json['uri'])
    map_field('archivesspace_resource_uri_ssi', @json['uri'])

    title_xml = @json['title']
    title_no_xml = EADHelper.strip_markup(@json['title'])

    map_field('title_ssm',              [title_no_xml])
    map_field('title_html_tesm',        [title_xml])
    map_field('title_tesim',            [title_no_xml])
    map_field('title_filing_ssi',       @json['finding_aid_filing_title'])
    map_field('ead_ssi',                resource_id(@json))

    map_field('unitdate_ssm',           @json['dates'].map{|d| format_date(d)})
    map_field('unitdate_bulk_ssim',     @json['dates'].select{|d| d['date_type'] == 'bulk'}.map{|d| format_date(d)})
    map_field('unitdate_inclusive_ssm', @json['dates'].select{|d| d['date_type'] == 'inclusive'}.map{|d| format_date(d)})
    map_field('unitdate_other_ssim',    @json['dates'].select{|d| !['bulk', 'inclusive'].include?(d['date_type'])}.map{|d| format_date(d)})

    map_field('level_ssm',              [@json['level']])
    map_field('level_ssim',             [@json['level'].capitalize])
    map_field('unitid_ssm',             [resource_id(@json)])
    map_field('unitid_tesim',           [resource_id(@json)])
    map_field('normalized_date_ssm',    [@json['dates'].map{|d| format_date(d)}.first]) # this can only be a single value as there's a solrCopy into single-value field (so take the first)
    map_field('normalized_title_ssm',   [collection_title(@json)])
    map_field('collection_title_tesim', [collection_title(@json)])
    map_field('collection_ssim',        [collection_title(@json)])
    map_field('repository_ssm',         [repository['name']]) # this has to match the 'name' in arclight's repositories.yml
    map_field('repository_ssim',        [repository['name']])
    map_field('creator_ssm',            @json['linked_agents'].select{|a| a['role'] == 'creator'}.map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('creator_ssim',           @map['creator_ssm'])
    map_field('creator_sort',           @json['linked_agents'].select{|a| a['role'] == 'creator'}.map{|a| a['_resolved']['names'].map{|n| n['sort_name']}}.flatten.uniq)
    map_field('creator_persname_ssim',  @map['creator_ssm'])
    map_field('creators_ssim',          @map['creator_ssm'])

    map_field('access_terms_ssm',       @json['notes']
                                              .select{|n| n['type'] == 'userestrict' && n['publish']}
                                              .map{|n| n['subnotes']
                                                         .select{|s| s['publish']}
                                                         .map{|s| s['content'].split(/\n+/)}}
                                              .flatten
                                              .map{|s| EADHelper.strip_markup(s)})

    map_field('access_subjects_ssim',   @json['subjects'].select{|s| s.dig('_resolved', 'terms', 0, 'term_type') == 'topical'}.map{|s| s['_resolved']['title']})
    map_field('access_subjects_ssm',    @map['access_subjects_ssim'])

    map_field('has_online_content_ssim',["Online access"]) if @json['_online_item_count'] > 0

    map_field('extent_ssm',             @json['extents'].map{|e| e['container_summary'] || "#{e['number']} #{I18n.t('enumerations.extent_extent_type.' + e['extent_type'], :default => e['extent_type'])}"})
    map_field('extent_tesim',           @map['extent_ssm'])

    map_field('genreform_ssim',         @json['subjects'].select{|s| s['_resolved']['publish']}.map{|s| s['_resolved']['terms']}.flatten.select{|t| t['term_type'] == 'genre_form'}.map{|t| t['term']})
    map_field('geogname_ssim',          @json['subjects'].select{|s| s['_resolved']['publish']}.map{|s| s['_resolved']['terms']}.flatten.select{|t| t['term_type'] == 'geographic'}.map{|t| t['term']})
    map_field('geogname_ssm',           @map['geogname_ssim'])
    map_field('places_ssim',            @map['geogname_ssim'])

    map_field('date_range_isim',        format_date_range(@json['dates']))

    map_field('names_coll_ssim',        @json['linked_agents'].map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('names_ssim',             @json['linked_agents'].map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('corpname_ssim',          @json['linked_agents'].select{|a| a['role'] == 'subject' && a['_resolved']['jsonmodel_type'] == 'agent_corporate_entity'}
                                                              .map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)
    map_field('persname_ssim',          @json['linked_agents'].select{|a| a['role'] == 'subject' && a['_resolved']['jsonmodel_type'] == 'agent_person'}
                                                              .map{|a| a['_resolved']['names'].map{|n| n['primary_name']}}.flatten.uniq)

    map_field('language_ssim',          @json['lang_materials'].map{|lm|
                                              out = lm['notes']
                                                      .map{|n| render_note(n)}
                                                      .flatten
                                                      .compact
                                                      .map{|ead| EADHelper.strip_markup(ead)}
                                                      .map{|s| s.split(/[,.]/)}
                                                      .flatten
                                                      .map(&:strip)
                                                      .reject(&:empty?)

                                              if (las = lm.dig('language_and_script', 'language'))
                                                out.unshift(I18n.t('enumerations.language_iso639_2.' + las))
                                              end

                                              out
                                            }.flatten.uniq)

    map_field('total_component_count_is',@json['_total_components'])
    map_field('online_item_count_is',   @json['_online_item_count'])
    map_field('component_level_isim',   [0])
    map_field('sort_isi',               0)

    map_notes
  end

end
