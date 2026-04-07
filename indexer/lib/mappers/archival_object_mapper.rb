class ArchivalObjectMapper < ArclightMapper

  # FIXME: a bit ouchy resolving ancestors - needed for various fields
  def self.resolves
    ['repository', 'resource', 'top_container', 'ancestors']
  end

  def repository
    @json['repository']['_resolved']
  end

  def resource
    @json['resource']['_resolved']
  end

  # aos don't need a title, if it isn't there, use display_string
  # the display_string is 'title, date'
  # FIXME: confirm traject mapping doesn't have date unless no title
  def title(json)
    json['title'] || json['display_string']
  end


  def ancestors
    @json['ancestors'].reverse.map{|a| a['_resolved']}
  end

  # FIXME: neither of these are required in the ao schema
  # but we need something reliable because it is used for the solr doc id
  def ao_ref
    @json['component_id'] || @json['ref_id'] || @json['uri']
  end

  def ao_id
    resource_id(resource) + '_' + ao_ref
  end

  def map
    map_field('ref_ssi',                     ao_ref)
    map_field('ref_ssm',                     [ao_ref, ao_ref]) # the traject mapping duplicates so here we are
    map_field('id',                          ao_id)
    map_field('title_filing_ssi',            title(@json))
    map_field('title_ssm',                   [title(@json)])
    map_field('title_tesim',                 [title(@json)])
    map_field('normalized_title_ssm',        [title(@json)])
    map_field('unitid_ssm',                  [ao_ref, @json['uri']])

    map_field('unitdate_ssm',                @json['dates'].map{|d| format_date(d)})
    map_field('unitdate_bulk_ssim',          @json['dates'].select{|d| d['date_type'] == 'bulk'}.map{|d| format_date(d)})
    map_field('unitdate_inclusive_ssm',      @json['dates'].select{|d| d['date_type'] == 'inclusive'}.map{|d| format_date(d)})
    map_field('unitdate_other_ssim',         @json['dates'].select{|d| !['bulk', 'inclusive'].include?(d['date_type'])}.map{|d| format_date(d)})

    map_field('component_level_isim',        [ancestors.length])
    map_field('parent_ids_ssim',             [resource_id(resource), ancestors[1..-1].map{|a| resource_id(resource) + '_' + (a['component_id'] || a['ref_id'] || a['uri'])}].flatten)
    map_field('parent_unittitles_ssm',       ancestors.map{|a| title(a)})
    map_field('parent_unittitles_tesim',     ancestors.map{|a| title(a)})
    map_field('parent_levels_ssm',           ancestors.map{|a| a['level']})
    map_field('repository_ssim',             [repository['name']])
    map_field('collection_ssim',             [resource['finding_aid_title']])
    map_field('creator_sort',                ['']) #FIXME
    map_field('has_online_content_ssim',     [false]) #FIXME
    map_field('child_component_count_isi',   [@json['_child_count']])
    map_field('level_ssm',                   [@json['level'].capitalize])
    map_field('level_ssim',                  [@json['level'].capitalize])
    map_field('sort_isi',                    [@json['position']])  #FIXME: is this right?

    map_field('parent_access_restrict_tesm',    resource['notes'].select{|n| n['type'] == 'accessrestrict'}
                                                              .map{|n| n['subnotes'].select{|s| s['publish']}
                                                              .map{|s| s['content'].split(/\n+/).map{|c| '<p>' + c + '</p>'}.join("\n") }.join("\n")})

    map_field('parent_access_terms_tesm',    resource['notes'].select{|n| n['type'] == 'userestrict'}
                                                              .map{|n| n['subnotes'].select{|s| s['publish']}
                                                              .map{|s| s['content'].split(/\n+/).map{|c| '<p>' + c + '</p>'}.join("\n") }.join("\n")})

    map_field('date_range_isim',             resource['dates'].map{|d| (d['begin'][0,4]..(d['end'] || d['begin'])[0,4]).to_a}.flatten.uniq)

    map_field('containers_ssim',             @json['instances'].select{|i| i['sub_container']}
                                                               .map{|i|
                                                                   [i['sub_container']['top_container']['_resolved']['display_string'],
                                                                    i['sub_container']['type_2'] + ' ' + i['sub_container']['indicator_2']]
                                                               }.flatten)

    map_notes

    super
  end
end
