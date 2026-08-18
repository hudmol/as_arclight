# An in-memory stand-in for the as_arclight backend endpoints that hold the
# indexer's state.
#
# Those endpoints talk to the ArchivesSpace database, so there's no way to
# reach them from a unit test run in isolation.  Rather than reimplement them
# here, this fake does the least it can get away with: it records every request
# it is given and hands back a canned response.  Tests assert on the requests -
# which is the indexer's half of the contract - and stub a response for the
# handful of endpoints whose answers the indexer actually acts on.
#
# Attach one to an indexer with #use_fake_backend (see ArclightBackendHelpers),
# which points ArclightIndexer#backend_get at it.
class FakeArclightBackend

  Request = Struct.new(:path, :params)

  attr_reader :requests

  def initialize
    @requests = []
    @responses = {}
  end

  # Set the response for path.  Either pass a value, or a block that will be
  # called with the request params.
  def stub(path, response = nil, &block)
    @responses[path] = block || proc { response }
  end

  # Called for us by ArclightIndexer#backend_get
  def handle(path, params = {})
    @requests << Request.new(path, params)

    responder = @responses.fetch(path) { proc { default_response_for(path, params) } }

    responder.call(params)
  end

  def paths
    requests.map(&:path)
  end

  def requests_for(path)
    requests.select{|request| request.path == path}
  end

  def params_for(path)
    requests_for(path).map(&:params)
  end

  def called?(path)
    !requests_for(path).empty?
  end

  # The uris the indexer has asked us to flag for indexing, in the order it
  # asked for them
  def flagged_for_indexing
    uris_from('/flag_for_indexing')
  end

  def unflagged_for_indexing
    uris_from('/remove_indexing_flag')
  end

  def flagged_for_delete
    uris_from('/flag_for_delete')
  end

  def unflagged_for_delete
    params_for('/remove_delete_flag').map{|params| params[:uri]}
  end

  def failures_recorded
    params_for('/increment_failure_count')
  end

  private

  def uris_from(path)
    params_for(path).flat_map{|params| Array(params['uris[]'])}
  end

  def default_response_for(path, params)
    case path
    when '/flag_for_indexing', '/flag_for_delete'
      # The real endpoint only flags resource uris and reports back what it
      # decided to do.  Accepting everything is the most useful default; the
      # examples that care about a rejection stub their own response.
      {'flagged' => Array(params['uris[]']), 'not_flagged' => []}
    when '/remove_indexing_flag'
      {'unflagged' => Array(params['uris[]']), 'not_unflagged' => []}
    when '/resources_to_index'
      {'uris' => [], 'failed' => []}
    when '/resources_to_delete'
      []
    when '/ancestors'
      Array(params['id_set[]']).map { {} }
    when %r{\A/repositories/[0-9]+/resources/[0-9]+\z}
      # the extra resource summary fields, which get merged into the resource
      {}
    else
      # /remove_delete_flag, /remove_all_indexing_flags, /increment_failure_count
      {'message' => 'success'}
    end
  end
end


module ArclightBackendHelpers

  def fake_backend
    @fake_backend ||= FakeArclightBackend.new
  end

  # Point an indexer's as_arclight backend calls at our in-memory fake.
  # Returns the indexer so it can be wrapped around a constructor call.
  def use_fake_backend(indexer)
    backend = fake_backend

    allow(indexer).to receive(:backend_get) do |path, params|
      backend.handle(path, params || {})
    end

    indexer
  end

  # IndexVersion checks the index version against the backend while an
  # ArclightIndexer is being constructed, so this needs to be in place before
  # any example builds one.  index_version_spec.rb covers the real thing.
  def stub_index_versions(versions = [])
    allow(IndexVersion).to receive(:fetch_index_versions).and_return(versions)
    allow(IndexVersion).to receive(:create_index_version)
  end
end
