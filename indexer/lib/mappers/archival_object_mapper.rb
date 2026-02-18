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

  def resource_id
    resource['ead_id'] || resource['id_0']
  end

  def ancestors
    @json['ancestors'].reverse.map{|a| a['_resolved']}
  end

  # FIXME: neither of these are required in the ao schema
  # but we need something reliable because it is used for the solr doc id
  def ao_ref
    @json['component_id'] || @json['ref_id'] || @json['uri']
  end

  def map
    map_field('ref_ssi',                     ao_ref)
    map_field('ref_ssm',                     [ao_ref, ao_ref]) # the traject mapping duplicates so here we are
    map_field('id',                          resource_id + '_' + ao_ref)
    map_field('title_filing_ssi',            @json['title'])
    map_field('title_ssm',                   [@json['title']])
    map_field('title_tesim',                 [@json['title']])
    map_field('normalized_title_ssm',        [@json['title']])
    map_field('component_level_isim',        [ancestors.length])
    map_field('parent_ids_ssim',             [resource_id, ancestors[1..-1].map{|a| resource_id + '_' + (a['component_id'] || a['ref_id'] || a['uri'])}].flatten)
    map_field('parent_unittitles_ssm',       ancestors.map{|a| a['title']})
    map_field('parent_unittitles_tesim',     ancestors.map{|a| a['title']})
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
