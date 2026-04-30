class Arclight::ArchivalObjectMapper < Arclight::Mapper

  # FIXME: a bit ouchy resolving ancestors - needed for various fields
  def self.resolves
    ['repository', 'resource', 'top_container', 'ancestors', 'instances::digital_object']
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
    if @json['ref_id']
      if AppConfig.has_key?(:as_arclight_ref_id_prefix)
        AppConfig[:as_arclight_ref_id_prefix] + @json['ref_id']
      else
        @json['ref_id']
      end
    else
      @json['component_id'] || @json['uri']
    end
  end

  def ao_id
    resource_id(resource) + '_' + ao_ref
  end

  def iiif_client
    unless @iiif_client
      config = IIIFClient::Config.new

      config.instance_eval do
        def configure_http_request(http, request)
          if request.uri.to_s.include?('albany.edu')
            request['Referer'] = 'https://archives.albany.edu/'
          end
        end

        def request_cache
          @cache_instance ||= IIIFClient::Cache::SQLiteCache.new(File.join(AppConfig[:data_directory], "iiif_cache.db"))
        end
      end

      @iiif_client = IIIFClient.new(config)
    end

    @iiif_client
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

    published_digital_object_instances = @json['instances'].select{|i| i.dig('digital_object', '_resolved', 'publish')}

    map_field(
      'digital_objects_ssm',
      published_digital_object_instances.map {|i|
        title = i.dig('digital_object', '_resolved', 'title')
        url = i.dig('digital_object', '_resolved', 'representative_file_version', 'file_uri')

        if title && url
          { label: title, href: url }.to_json
        else
          nil
        end
      }.compact
    )


    iiif_text = []

    published_digital_object_instances.each do |instance|
      digital_object = instance.dig('digital_object', '_resolved')

      digital_object.fetch('file_versions', []).each do |file_version|
        decoded_uri = URI.decode_www_form_component(file_version.fetch('file_uri', ''))
        manifest_uri = decoded_uri.scan(%r{(?=(https?://.*manifest.json))}i).flatten.min_by(&:length)

        if manifest_uri
          iiif = iiif_client

          manifest = iiif.fetch_manifest(manifest_uri)

          manifest.metadata.each do |metadata|
            iiif_text << "#{metadata.label.value}: #{metadata.value.value}"
          end

          manifest.annotations.each do |annotation|
            annotation.item.body.each do |b|
              iiif_text << body
            end
          end

          # If there is a top-level rendering, take that
          renderings = manifest.renderings.select {|tree_item| tree_item.path_str !~ %r{^items}}.map(&:item)

          # But fall back to item-level renderings if we have nothing better
          if renderings.empty?
            renderings = manifest.renderings.map(&:item)
          end

          iiif.extract_rendering_text(renderings) do |rendering_text|
            if rendering_text.is_success?
              iiif_text << rendering_text.text.strip
            end
          end
        end
      end
    end

    map_field('text', iiif_text)

    map_notes

    super
  end
end
