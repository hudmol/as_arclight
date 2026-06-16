require 'uri'
require 'json'
require_relative '../../indexer/lib/mappers/arclight_mapper'
require_relative '../../indexer/lib/iiif_client'

describe Arclight::ArchivalObjectMapper do
  def fixture_path(name)
    File.expand_path(File.join(File.dirname(__FILE__), '..', 'fixtures', name))
  end

  # Base builder for archival JSON; override keys by passing a hash to `overrides`
  def minimal_archival_json(overrides = {})
    resource_resolved = {
      'ead_id' => 'res-001',
      'title' => 'Res Title',
      'dates' => [
        { 'date_type' => 'inclusive', 'expression' => '2000-2002', 'begin' => '2000', 'end' => '2002' }
      ],
      'notes' => [
        # accessrestrict note
        {
          'type' => 'accessrestrict',
          'publish' => true,
          'subnotes' => [
            { 'content' => 'Restricted content', 'publish' => true }
          ]
        },
        # userestrict note
        {
          'type' => 'userestrict',
          'publish' => true,
          'subnotes' => [
            { 'content' => 'Contact archives for permission', 'publish' => true }
          ]
        }
      ],
      '_resolved' => true
    }

    base = {
      'title' => 'Sample AO Title',
      'display_string' => 'Sample AO Title',
      'level' => 'series',
      'position' => 1,
      'ref_id' => 'AO-1',
      'dates' => [
        { 'date_type' => 'inclusive', 'expression' => '1990-1995', 'begin' => '1990', 'end' => '1995' }
      ],
      'extents' => [
        { 'number' => '5', 'extent_type' => 'boxes', 'container_summary' => '5 boxes' }
      ],
      'ancestors' => [
        { '_resolved' => { 'display_string' => 'Parent Title', 'level' => 'collection', 'ref_id' => 'PARENT', 'component_id' => 'PARENT-1' } }
      ],
      'repository' => { '_resolved' => { 'name' => 'Test Repository' } },
      'resource' => { '_resolved' => resource_resolved },
      'linked_agents' => [],
      'instances' => [], # no digital objects by default; IIIF test will add an instance
      '_child_count' => 3
    }

    base.merge(overrides)
  end

  context 'IIIF integration and rendering extraction' do

    def ao_json_with_iiif_manifest(manifest_url)
      minimal_archival_json({
                              'instances' => [
                                {
                                  'digital_object' => {
                                    '_resolved' => {
                                      'title' => 'Digital Object 1',
                                      'publish' => true,
                                      'representative_file_version' => { 'file_uri' => manifest_url },
                                      'file_versions' => [
                                        { 'file_uri' => manifest_url }
                                      ]
                                    }
                                  }
                                }
                              ]
                            })
    end



    it 'lets IIIFClient#fetch_manifest parse the manifest fixture, and uses extract_rendering_text to pull TXT contents' do
      # read the manifest fixture; use this as the HTTP body returned by fetch_url
      manifest_body = File.read(fixture_path('example_v3_iiif_manifest.json')).force_encoding('UTF-8')

      # read content fixtures we want extract_rendering_text to return
      txt_content = File.read(fixture_path('example_iiif_content.txt'), mode: 'rb')

      # Stub IIIFClient#fetch_url so that fetch_manifest reads our fixture JSON
      allow_any_instance_of(IIIFClient).to receive(:fetch_url).and_return(
        IIIFClient::HTTPResponse.new('200', { 'content-type' => ['application/json'] }, manifest_body)
      )

      # stub extract_rendering_text to inspect the renderings array and yield the two fixture contents
      allow_any_instance_of(IIIFClient).to receive(:extract_rendering_text) do |_iiif, renderings, &block|
        urls = renderings.map(&:url)
        # assert the two expected rendering urls are present in the renderings provided by the parser
        expect(urls).to include('https://example.org/123/content.txt')

        renderings.each do |r|
          content = case r.url
                    when 'https://example.org/123/content.txt' then txt_content
                    else ''
                    end

          block.call(IIIFClient::ExtractRenderingTextResult.new(true, r, nil, content, nil))
        end
      end

      # Build an archival object JSON with one published digital object instance whose file_versions
      # contain an encoded manifest URL (the mapper will decode and scan for a manifest URL)
      manifest_url = URI.encode_www_form_component("http://example.org/fixtures/example_v3_iiif_manifest.json")

      archival_json = ao_json_with_iiif_manifest(manifest_url)

      mapper = Arclight::ArchivalObjectMapper.new(archival_json)
      mapped = JSON.parse(mapper.json)

      # ensure mapper collected IIIF text: at minimum the TXT content appear in the text field
      expect(mapped['text']).to be_an(Array)
      expect(mapped['text'].any? { |t| t.to_s.include?(txt_content) }).to be_truthy

      # digital_objects_ssm should include a JSON string with label and href (href is the encoded uri we provided)
      expect(mapped['digital_objects_ssm']).to be_an(Array)
      parsed_digital = mapped['digital_objects_ssm'].map { |s| JSON.parse(s) rescue nil }.compact
      expect(parsed_digital.any? { |o| o['label'] == 'Digital Object 1' && o['href'] == manifest_url }).to be_truthy

      # has_online_content_ssim should indicate online access
      expect(mapped['has_online_content_ssim']).to include('Online access')
    end

    it 'logs the failing manifest uri and error when a rendering cannot be extracted' do
      manifest_body = File.read(fixture_path('example_v3_iiif_manifest.json')).force_encoding('UTF-8')

      allow_any_instance_of(IIIFClient).to receive(:fetch_url).and_return(
        IIIFClient::HTTPResponse.new('200', { 'content-type' => ['application/json'] }, manifest_body)
      )

      # Force every rendering to come back as a failure result carrying an HTTPError
      error = IIIFClient::Errors::HTTPError.new('Unexpected HTTP response (status=500; url=https://example.org/123/content.txt)')
      allow_any_instance_of(IIIFClient).to receive(:extract_rendering_text) do |_iiif, renderings, &block|
        renderings.each do |r|
          block.call(IIIFClient::ExtractRenderingTextResult.new(false, r, nil, nil, error))
        end
      end

      manifest_url = URI.encode_www_form_component('http://example.org/fixtures/example_v3_iiif_manifest.json')
      decoded_manifest_uri = 'http://example.org/fixtures/example_v3_iiif_manifest.json'

      archival_json = ao_json_with_iiif_manifest(manifest_url)

      allow(Log).to receive(:info)

      mapper = Arclight::ArchivalObjectMapper.new(archival_json)
      JSON.parse(mapper.json)

      expect(Log).to have_received(:info)
        .with(/failure while extracting renderings from IIIF manifest #{Regexp.escape(decoded_manifest_uri)}/)
        .at_least(:once)
      expect(Log).to have_received(:info)
        .with(/error was #{Regexp.escape(error.message)}/)
        .at_least(:once)
    end
  end

  context 'mapping of core archival object fields' do
    it 'maps ref/id/title/unitid and basic parent/collection/repository fields' do
      archival_json = minimal_archival_json

      mapper = Arclight::ArchivalObjectMapper.new(archival_json)
      map = JSON.parse(mapper.json)

      # ref fields and duplicates
      expect(map['ref_ssi']).to eq('AO-1')
      expect(map['ref_ssm']).to be_an(Array)
      expect(map['ref_ssm'].length).to be >= 1

      # id is resource_id(resource) + '_' + archival_object_id
      expect(map['id']).to be_a(String)
      expect(map['title_ssm']).to eq(['Sample AO Title'])
      expect(map['title_tesim']).to eq(['Sample AO Title'])
      expect(map['title_html_tesm']).to eq(['Sample AO Title'])
      expect(map['normalized_title_ssm']).to eq(['Sample AO Title'])

      # unitid includes archival ID (uri is optional)
      expect(map['unitid_ssm']).to include('AO-1')

      # repository and collection fields
      expect(map['repository_ssim']).to eq(['Test Repository'])
      expect(map['repository_ssm']).to eq(['Test Repository'])
      expect(map['collection_ssim']).to be_an(Array)
      expect(map['collection_ssim'].first).to include('Res Title')
    end

    it 'maps unitdate, date_range and normalized_date correctly' do
      archival_json = minimal_archival_json

      mapper = Arclight::ArchivalObjectMapper.new(archival_json)
      map = JSON.parse(mapper.json)

      expect(map['unitdate_ssm']).to include('1990-1995')
      expect(map['unitdate_inclusive_ssm']).to include('1990-1995')

      expect(map['date_range_isim']).to include('1990', '1991', '1992', '1993', '1994', '1995')
      expect(map['normalized_date_ssm']).to include('1990-1995')
    end

    it 'maps extents and component counts and levels' do
      archival_json = minimal_archival_json({
                                              'extents' => [
                                                { 'number' => '2', 'extent_type' => 'volumes', 'container_summary' => '2 volumes' }
                                              ],
                                            })

      mapper = Arclight::ArchivalObjectMapper.new(archival_json)
      map = JSON.parse(mapper.json)

      expect(map['extent_ssm']).to include('2 volumes')
      expect(map['extent_tesim']).to eq(map['extent_ssm'])
      expect(map['child_component_count_isi']).to eq([3])
      expect(map['component_level_isim']).to eq([1]) # ancestors length = 1
      expect(map['level_ssm']).to eq(['Series'])
      expect(map['sort_isi']).to eq(1)
    end

    it 'maps parent ids, parent unittitles and parent levels' do
      archival_json = minimal_archival_json

      mapper = Arclight::ArchivalObjectMapper.new(archival_json)
      map = JSON.parse(mapper.json)

      # parent_ids_ssim should include the resource id
      expect(map['parent_ids_ssim']).to include('res-001')
      # parent_unittitles should include the collection title
      expect(map['parent_unittitles_ssm'].first).to include('Res Title')
      # parent_levels should include the ancestor level 'collection'
      expect(map['parent_levels_ssm']).to include('collection')
    end

    it 'maps parent access notes from resource notes' do
      archival_json = minimal_archival_json

      mapper = Arclight::ArchivalObjectMapper.new(archival_json)
      map = JSON.parse(mapper.json)

      # Expect parent access restrict HTML and userestrict HTML to be present
      expect(map['parent_access_restrict_tesm'].first).to include('<p>Restricted content</p>')
      expect(map['parent_access_terms_tesm'].first).to include('<p>Contact archives for permission</p>')
    end

    it 'maps containers from instances with sub_container' do
      # Create a sub_container instance to be mapped
      instance_with_sub = {
        'sub_container' => {
          'top_container' => { '_resolved' => { 'display_string' => 'Top Container 1' } },
          'type_2' => 'Box',
          'indicator_2' => '5'
        }
      }

      archival_json = minimal_archival_json({
                                              'instances' => [instance_with_sub]
                                            })

      mapper = Arclight::ArchivalObjectMapper.new(archival_json)
      map = JSON.parse(mapper.json)

      expect(map['containers_ssim']).to include('Top Container 1')
      expect(map['containers_ssim'].join(' ')).to include('Box')
    end

    it 'maps creator_sort from linked_agents on the archival object' do
      archival_json = minimal_archival_json({
                                              'linked_agents' => [
                                                {
                                                  'role' => 'creator',
                                                  '_resolved' => {
                                                    'names' => [
                                                      { 'sort_name' => 'Smith, John' }
                                                    ]
                                                  }
                                                }
                                              ]
                                            })

      mapper = Arclight::ArchivalObjectMapper.new(archival_json)
      map = JSON.parse(mapper.json)

      expect(map['creator_sort']).to include('Smith, John')
    end
  end
end
