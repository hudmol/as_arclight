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

  def ancestors
    @json['ancestors'].reverse.map{|a| a['_resolved']}
  end

  def archival_object_id(ao_json)
    id = ao_json['ref_id'] || ao_json['component_id'] || ao_json['uri']
    id.tr('.', '-')
  end

  def ao_id(ao_json)
    resource_id(resource) + AppConfig[:as_arclight_archival_object_id_delimiter] + archival_object_id(ao_json)
  end

  def iiif_client
    unless @iiif_client
      config = IIIFClient::Config.new

      # FIXME: albany-specific
      config.instance_eval do
        def configure_http_request(http, request)
          if request.uri.to_s.include?('albany.edu')
            request['Referer'] = 'https://archives.albany.edu/'
          end
        end
      end

      @iiif_client = IIIFClient.new(config)
    end

    @iiif_client
  end

  def map
    map_field('id',                          ao_id(@json))
    map_field('archivesspace_uri_ssi',       @json['uri'])
    map_field('archivesspace_resource_uri_ssi', resource['uri'])

    map_field('ref_ssi',                     archival_object_id(@json))
    map_field('ref_ssm',                     [archival_object_id(@json), archival_object_id(@json)]) # the traject mapping duplicates so here we are

    title_xml = @json['display_string']
    title_no_xml = EADHelper.strip_markup(@json['display_string'])

    map_field('title_filing_ssi',            title_no_xml)
    map_field('title_ssm',                   [title_no_xml])
    map_field('title_tesim',                 [title_no_xml])
    map_field('title_html_tesm',             [title_xml])
    map_field('normalized_title_ssm',        [title_no_xml])

    map_field('unitid_ssm',                  [archival_object_id(@json), @json['uri']])

    map_field('unitdate_ssm',                @json['dates'].map{|d| format_date(d)})
    map_field('unitdate_bulk_ssim',          @json['dates'].select{|d| d['date_type'] == 'bulk'}.map{|d| format_date(d)})
    map_field('unitdate_inclusive_ssm',      @json['dates'].select{|d| d['date_type'] == 'inclusive'}.map{|d| format_date(d)})
    map_field('unitdate_other_ssim',         @json['dates'].select{|d| !['bulk', 'inclusive'].include?(d['date_type'])}.map{|d| format_date(d)})

    map_field('extent_ssm',                  @json['extents'].map{|e| e['container_summary'] || "#{e['number']} #{I18n.t('enumerations.extent_extent_type.' + e['extent_type'], :default => e['extent_type'])}"})
    map_field('extent_tesim',                @map['extent_ssm'])

    map_field('component_level_isim',        [ancestors.length])
    map_field('parent_ids_ssim',             [resource_id(resource), ancestors[1..-1].map{|a| ao_id(a)}].flatten)
    map_field('parent_ssi',                  @map['parent_ids_ssim'].last)
    map_field('parent_ssim',                 @map['parent_ids_ssim'])

    map_field('parent_unittitles_ssm',       [collection_title(resource), ancestors[1..-1].map{|a| EADHelper.strip_markup(a['display_string'])}].select{|a| !a.nil?}.flatten)
    map_field('parent_unittitles_tesim',     @map['parent_unittitles_ssm'])

    map_field('parent_levels_ssm',           ancestors.map{|a| a['level']})
    map_field('repository_ssim',             [repository['name']])
    map_field('repository_ssm',              [repository['name']])
    map_field('collection_ssim',             [collection_title(resource)])
    map_field('creator_sort',                @json['linked_agents'].select{|a| a['role'] == 'creator'}.map{|a| a['_resolved']['names'].map{|n| n['sort_name']}}.flatten.uniq)
    map_field('child_component_count_isi',   [@json['_child_count']])
    map_field('level_ssm',                   [@json['level'].capitalize])
    map_field('level_ssim',                  [@json['level'].capitalize])
    map_field('sort_isi',                    @json['position'])

    map_field('parent_access_restrict_tesm', resource['notes']
                                                    .select{|n| n['type'] == 'accessrestrict'}
                                                    .map{|n| n['subnotes']
                                                               .select{|s| s['publish']}
                                                               .map{|s| render_note(s)}}
                                                    .flatten
                                                    .map{|ead| EADHelper.strip_markup(ead)})

    map_field('parent_access_terms_tesm',    resource['notes']
                                                    .select{|n| n['type'] == 'userestrict'}
                                                    .map{|n| n['subnotes']
                                                              .select{|s| s['publish']}
                                                              .map{|s| s['content'].split(/\n+/).map{|c| '<p>' + c + '</p>'}}}
                                                    .flatten
                                                    .map{|s| EADHelper.strip_markup(s)})

    map_field('date_range_isim',             format_date_range(@json['dates']))

    map_field('normalized_date_ssm',         @map['date_range_isim'].length == 1 ? @map['date_range_isim'].first : [@map['date_range_isim'].first, @map['date_range_isim'].last].join('-'))

    map_field('containers_ssim',             @json['instances'].select{|i| i['sub_container']}
                                                               .map{|i|
                                                                   [
                                                                     i['sub_container']['top_container']['_resolved']['display_string'],
                                                                     [
                                                                       i['sub_container']['type_2'],
                                                                       i['sub_container']['indicator_2']
                                                                     ].compact.join(' ')
                                                                   ].reject(&:empty?)
                                                               }.flatten)

    published_digital_object_instances = @json['instances'].select{|i| i.dig('digital_object', '_resolved', 'publish')}

    map_field(
      'digital_objects_ssm',
      published_digital_object_instances.map {|i|
        title = EADHelper.strip_markup(i.dig('digital_object', '_resolved', 'title'))
        url = i.dig('digital_object', '_resolved', 'representative_file_version', 'file_uri')

        if title && url
          { label: title, href: url }.to_json
        else
          nil
        end
      }.compact
    )

    map_field('has_online_content_ssim', ["Online access"]) unless published_digital_object_instances.empty?

    iiif_text = []
    dado_fields = []

    published_digital_object_instances.each do |instance|
      digital_object = instance.dig('digital_object', '_resolved')

      if AppConfig.has_key?(:include_dadocm_required_fields) && AppConfig[:include_dadocm_required_fields]
        if representative_file_version = digital_object['representative_file_version']
          dado_fields << {
            :dado_action_ssm => representative_file_version['xlink_show_attribute'],
            :dado_identifier_ssm => representative_file_version['file_uri'],
            :dado_label_tesim => EADHelper.strip_markup(digital_object['title']),
            :dado_type_ssm => digital_object['digital_object_type'] ? I18n.t("enumerations.digital_object_digital_object_type.#{digital_object['digital_object_type']}", :default => digital_object['digital_object_type'])
                                                                    : 'unset'
          }
        end
      end

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
              iiif_text << b.value
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
            else
              ARCLog.error "failure while extracting renderings from IIIF manifest #{manifest_uri}"
              ARCLog.error "error was #{rendering_text.error}"

              raise rendering_text.error
            end
          end
        end
      end
    end

    # Clean up any invalid chars and ensure we get UTF-8
    map_field('text', iiif_text.map {|text| text.scrub("?").encode('UTF-8', undef: :replace, replace: '?')})

    unless dado_fields.empty?
      # FIXME: the solr fields are multis, but the existing mapping has single values
      # so just taking the first for now.
      dado_fields.first.each do |k,v|
        map_field(k, v)
      end
    end

    map_notes
  end
end
