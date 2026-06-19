require_relative '../../indexer/lib/mappers/arclight_mapper'

describe Arclight::ResourceMapper do

  # Helper to create a minimal resource JSON structure
  def minimal_resource
    {
      'title' => "Sample Collection",
      'ead_id' => 'sample-001',
      'id_0' => 'sample',
      'id_1' => nil,
      'id_2' => nil,
      'id_3' => nil,
      'finding_aid_filing_title' => 'Collection, Sample',
      'level' => 'collection',
      'publish' => true,
      'repository' => {
        '_resolved' => {
          'name' => 'Test Repository',
          'publish' => true
        }
      },
      'dates' => [],
      'extents' => [],
      'notes' => [],
      'subjects' => [],
      'linked_agents' => [],
      'lang_materials' => [],
      '_total_components' => 0,
      '_online_item_count' => 0
    }
  end

  describe '#map' do
    context 'with basic required fields' do
      it 'maps title fields correctly' do
        resource_json = minimal_resource
        mapper = Arclight::ResourceMapper.new(resource_json)

        expect(mapper.doc_id).to eq('sample-001')
        map = JSON.parse(mapper.json)
        expect(map['title_ssm']).to eq(['Sample Collection'])
        expect(map['title_html_tesm']).to eq(['Sample Collection'])
        expect(map['title_tesim']).to eq(['Sample Collection'])
      end

      it 'maps repository name' do
        resource_json = minimal_resource
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['repository_ssm']).to eq(['Test Repository'])
        expect(map['repository_ssim']).to eq(['Test Repository'])
      end

      it 'maps level and capitalizes it' do
        resource_json = minimal_resource
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['level_ssm']).to eq(['collection'])
        expect(map['level_ssim']).to eq(['Collection'])
      end

      it 'maps unitid from resource_id' do
        resource_json = minimal_resource
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['unitid_ssm']).to eq(['sample-001'])
        expect(map['unitid_tesim']).to eq(['sample-001'])
      end

      it 'maps component counts' do
        resource_json = minimal_resource.merge({
          '_total_components' => 42,
          '_online_item_count' => 5
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['total_component_count_is']).to eq(42)
        expect(map['online_item_count_is']).to eq(5)
        expect(map['component_level_isim']).to eq([0])
        expect(map['sort_isi']).to eq(0)
      end
    end

    context 'with dates' do
      it 'maps inclusive dates' do
        resource_json = minimal_resource.merge({
          'dates' => [
            {
              'date_type' => 'inclusive',
              'expression' => '1950-1975',
              'begin' => '1950',
              'end' => '1975'
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['unitdate_inclusive_ssm']).to eq(['1950-1975'])
        expect(map['unitdate_ssm']).to eq(['1950-1975'])
        expect(map['normalized_date_ssm']).to eq(['1950-1975'])
      end

      it 'maps bulk dates separately' do
        resource_json = minimal_resource.merge({
          'dates' => [
            {
              'date_type' => 'inclusive',
              'expression' => '1950-1975',
              'begin' => '1950',
              'end' => '1975'
            },
            {
              'date_type' => 'bulk',
              'expression' => '1960-1970',
              'begin' => '1960',
              'end' => '1970'
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['unitdate_bulk_ssim']).to eq(['bulk 1960-1970'])
        expect(map['unitdate_ssm'].sort).to eq(['1950-1975', 'bulk 1960-1970'].sort)
      end

      it 'builds date_range_isim from date years' do
        resource_json = minimal_resource.merge({
          'dates' => [
            {
              'date_type' => 'inclusive',
              'begin' => '1960',
              'end' => '1965'
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['date_range_isim']).to include('1960', '1961', '1962', '1963', '1964', '1965')
      end

      it 'handles collection_title with dates' do
        resource_json = minimal_resource.merge({
          'dates' => [
            {
              'date_type' => 'inclusive',
              'expression' => '1950-1975',
              'begin' => '1950',
              'end' => '1975'
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['collection_title_tesim']).to eq(['Sample Collection, 1950-1975'])
        expect(map['collection_ssim']).to eq(['Sample Collection, 1950-1975'])
        expect(map['normalized_title_ssm']).to eq(['Sample Collection, 1950-1975'])
      end
    end

    context 'with extents' do
      it 'maps container_summary when present' do
        resource_json = minimal_resource.merge({
          'extents' => [
            {
              'number' => '5',
              'extent_type' => 'pages',
              'container_summary' => '5 boxes'
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['extent_ssm']).to eq(['5 boxes'])
        expect(map['extent_tesim']).to eq(['5 boxes'])
      end

      it 'formats extent as number + type when no container_summary' do
        resource_json = minimal_resource.merge({
          'extents' => [
            {
              'number' => '12',
              'extent_type' => 'folders'
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        # The mapper uses I18n, so we just check it includes the number
        expect(map['extent_ssm']).to include(/^12/)
      end
    end

    context 'with linked_agents (creators)' do
      it 'maps creator agents' do
        resource_json = minimal_resource.merge({
          'linked_agents' => [
            {
              'role' => 'creator',
              '_resolved' => {
                'names' => [
                  { 'primary_name' => 'Smith, John', 'sort_name' => 'Smith, John' }
                ]
              }
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['creator_ssm']).to eq(['Smith, John'])
        expect(map['creator_ssim']).to eq(['Smith, John'])
        expect(map['creator_sort']).to eq(['Smith, John'])
        expect(map['creator_persname_ssim']).to eq(['Smith, John'])
        expect(map['creators_ssim']).to eq(['Smith, John'])
      end

      it 'maps names_coll_ssim and names_ssim from all linked agents' do
        resource_json = minimal_resource.merge({
          'linked_agents' => [
            {
              'role' => 'creator',
              '_resolved' => {
                'names' => [
                  { 'primary_name' => 'Smith, John' }
                ]
              }
            },
            {
              'role' => 'subject',
              '_resolved' => {
                'names' => [
                  { 'primary_name' => 'Jones, Mary' }
                ]
              }
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['names_coll_ssim']).to include('Smith, John', 'Jones, Mary')
        expect(map['names_ssim']).to include('Smith, John', 'Jones, Mary')
      end

      it 'maps corpname_ssim for corporate entities with subject role' do
        resource_json = minimal_resource.merge({
          'linked_agents' => [
            {
              'role' => 'subject',
              '_resolved' => {
                'jsonmodel_type' => 'agent_corporate_entity',
                'names' => [
                  { 'primary_name' => 'Acme Corporation' }
                ]
              }
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['corpname_ssim']).to eq(['Acme Corporation'])
      end

      it 'maps persname_ssim for person agents with subject role' do
        resource_json = minimal_resource.merge({
          'linked_agents' => [
            {
              'role' => 'subject',
              '_resolved' => {
                'jsonmodel_type' => 'agent_person',
                'names' => [
                  { 'primary_name' => 'Doe, Jane' }
                ]
              }
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['persname_ssim']).to eq(['Doe, Jane'])
      end
    end

    context 'with subjects' do
      it 'maps topical subjects to access_subjects' do
        resource_json = minimal_resource.merge({
          'subjects' => [
            {
              '_resolved' => {
                'title' => 'Architecture',
                'publish' => true,
                'terms' => [
                  { 'term_type' => 'topical', 'term' => 'Architecture' }
                ]
              }
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['access_subjects_ssim']).to eq(['Architecture'])
        expect(map['access_subjects_ssm']).to eq(['Architecture'])
      end

      it 'maps genreform terms' do
        resource_json = minimal_resource.merge({
          'subjects' => [
            {
              '_resolved' => {
                'publish' => true,
                'terms' => [
                  { 'term_type' => 'genre_form', 'term' => 'Photographs' }
                ]
              }
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['genreform_ssim']).to eq(['Photographs'])
      end

      it 'maps geogname terms and places' do
        resource_json = minimal_resource.merge({
          'subjects' => [
            {
              '_resolved' => {
                'publish' => true,
                'terms' => [
                  { 'term_type' => 'geographic', 'term' => 'New York' }
                ]
              }
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['geogname_ssim']).to eq(['New York'])
        expect(map['geogname_ssm']).to eq(['New York'])
        expect(map['places_ssim']).to eq(['New York'])
      end

      it 'filters out unpublished subjects' do
        resource_json = minimal_resource.merge({
          'subjects' => [
            {
              '_resolved' => {
                'publish' => false,
                'terms' => [
                  { 'term_type' => 'genre_form', 'term' => 'Hidden Photographs' }
                ]
              }
            },
            {
              '_resolved' => {
                'publish' => true,
                'terms' => [
                  { 'term_type' => 'genre_form', 'term' => 'Visible Photographs' }
                ]
              }
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['genreform_ssim']).to eq(['Visible Photographs'])
        expect(map['genreform_ssim']).not_to include('Hidden Photographs')
      end
    end

    context 'with online content' do
      it 'sets has_online_content_ssim when _online_item_count > 0' do
        resource_json = minimal_resource.merge({
          '_online_item_count' => 1
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['has_online_content_ssim']).to eq(['Online access'])
      end

      it 'does not set has_online_content_ssim when count is 0' do
        resource_json = minimal_resource.merge({
          '_online_item_count' => 0
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map).not_to have_key('has_online_content_ssim')
      end
    end

    context 'with access restrictions' do
      it 'maps userestrict notes to access_terms' do
        resource_json = minimal_resource.merge({
          'notes' => [
            {
              'jsonmodel_type' => 'note_multipart',
              'type' => 'userestrict',
              'publish' => true,
              'subnotes' => [
                { 'jsonmodel_type' => 'note_singlepart', 'content' => 'Restricted materials', 'publish' => true },
                { 'jsonmodel_type' => 'note_singlepart', 'content' => 'Contact archives for permission', 'publish' => true }
              ]
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['access_terms_ssm']).to include('Restricted materials')
        expect(map['access_terms_ssm']).to include('Contact archives for permission')
      end

      it 'filters out unpublished access restriction subnotes' do
        resource_json = minimal_resource.merge({
          'notes' => [
            {
              'jsonmodel_type' => 'note_multipart',
              'type' => 'userestrict',
              'publish' => true,
              'subnotes' => [
                { 'jsonmodel_type' => 'note_singlepart', 'content' => 'Published restriction', 'publish' => true },
                { 'jsonmodel_type' => 'note_singlepart', 'content' => 'Hidden restriction', 'publish' => false }
              ]
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['access_terms_ssm']).to include('Published restriction')
        expect(map['access_terms_ssm']).not_to include('Hidden restriction')
      end
    end

    context 'with multipart notes' do
      it 'maps scopecontent notes' do
        resource_json = minimal_resource.merge({
          'notes' => [
            {
              'jsonmodel_type' => 'note_multipart',
              'type' => 'scopecontent',
              'publish' => true,
              'subnotes' => [
                { 'jsonmodel_type' => 'note_singlepart', 'content' => 'This collection contains letters and documents.', 'publish' => true }
              ]
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['scopecontent_heading_ssm']).not_to be_empty
        expect(map['scopecontent_tesm']).to include('This collection contains letters and documents.')
        expect(map['scopecontent_tesim']).to include('This collection contains letters and documents.')
        expect(map['scopecontent_html_tesm']).not_to be_empty
      end

      it 'maps acqinfo notes' do
        resource_json = minimal_resource.merge({
          'notes' => [
            {
              'jsonmodel_type' => 'note_multipart',
              'type' => 'acqinfo',
              'publish' => true,
              'subnotes' => [
                { 'jsonmodel_type' => 'note_singlepart', 'content' => 'Donated in 1995.', 'publish' => true }
              ]
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['acqinfo_heading_ssm']).not_to be_empty
        expect(map['acqinfo_tesm']).to include('Donated in 1995.')
        expect(map['acqinfo_ssim']).to include('Donated in 1995.')
      end
    end

    context 'with singlepart notes' do
      it 'maps abstract notes' do
        resource_json = minimal_resource.merge({
          'notes' => [
            {
              'jsonmodel_type' => 'note_abstract',
              'type' => 'abstract',
              'publish' => true,
              'content' => ['A brief overview of the collection']
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['abstract_heading_ssm']).not_to be_empty
        expect(map['abstract_tesim']).to include('A brief overview of the collection')
        expect(map['abstract_html_tesm']).not_to be_empty
      end
    end

    context 'with ordered list notes' do
      it 'maps arrangement notes with items' do
        resource_json = minimal_resource.merge({
          'notes' => [
            {
              'jsonmodel_type' => 'note_multipart',
              'type' => 'arrangement',
              'publish' => true,
              'subnotes' => [
                { 'jsonmodel_type' => 'note_orderedlist', 'items' => ['Series 1: Correspondence', 'Series 2: Photographs'], 'publish' => true }
              ]
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['arrangement_heading_ssm']).not_to be_empty
        expect(map['arrangement_tesm']).to include(a_string_including('Series 1: Correspondence'))
        expect(map['arrangement_tesm']).to include(a_string_including('Series 2: Photographs'))
        expect(map['arrangement_html_tesm']).to include(a_string_including('<item>Series 1: Correspondence</item>'))
        expect(map['arrangement_html_tesm']).to include(a_string_including('<item>Series 2: Photographs</item>'))
      end
    end

    context 'with language materials' do
      it 'maps language materials with ISO 639-2 code' do
        resource_json = minimal_resource.merge({
          'lang_materials' => [
            {
              'language_and_script' => {
                'language' => 'eng'
              },
              'notes' => []
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        # The mapper uses I18n to translate the code, so we just check it's present
        expect(map['language_ssim']).not_to be_empty
      end

      it 'maps language notes content' do
        resource_json = minimal_resource.merge({
          'lang_materials' => [
            {
              'notes' => [
                { 'jsonmodel_type' => 'note_langmaterial', 'content' => 'English, French', 'publish' => true }
              ]
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['language_ssim']).to include('English', 'French')
      end
    end

    context 'with multiple dates' do
      it 'takes the first date for normalized_date_ssm' do
        resource_json = minimal_resource.merge({
          'dates' => [
            {
              'date_type' => 'inclusive',
              'expression' => '1950-1975',
              'begin' => '1950',
              'end' => '1975'
            },
            {
              'date_type' => 'other',
              'expression' => '1980',
              'begin' => '1980',
              'end' => '1980'
            }
          ]
        })
        mapper = Arclight::ResourceMapper.new(resource_json)
        map = JSON.parse(mapper.json)

        expect(map['normalized_date_ssm']).to eq(['1950-1975'])
      end
    end

    context 'with resource_id generation' do
      it 'uses ead_id if available' do
        resource_json = minimal_resource.merge({
          'ead_id' => 'custom-ead-001'
        })
        mapper = Arclight::ResourceMapper.new(resource_json)

        expect(mapper.doc_id).to eq('custom-ead-001')
      end

      it 'composes from id_0 through id_3 if no ead_id' do
        resource_json = minimal_resource.merge({
          'ead_id' => nil,
          'id_0' => 'part1',
          'id_1' => 'part2',
          'id_2' => nil,
          'id_3' => 'part3'
        })
        mapper = Arclight::ResourceMapper.new(resource_json)

        expect(mapper.doc_id).to eq('part1-part2-part3')
      end
    end
  end

  describe '.resolves' do
    it 'returns the expected resolve array for API calls' do
      resolves = Arclight::ResourceMapper.resolves

      expect(resolves).to include('repository', 'linked_agents', 'subjects')
    end
  end
end