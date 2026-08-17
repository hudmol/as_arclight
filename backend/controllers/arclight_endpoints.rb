class ArchivesSpaceService < Sinatra::Base

  # FIXME: some of these should probably be posts
  Endpoint.get('/as_arclight/flag_for_indexing')
    .description("Flag Resource URIs for Arclight indexing")
    .params(["uris", [String], "The Resource URIs to flag"])
    .permissions([:index_system])
    .returns([200, "success"]) \
  do
    DB.open do |db|

      out = {:flagged => [], :not_flagged => []}

      params[:uris].each do |uri|
        parsed_ref = JSONModel.parse_reference(uri)

        # we only flag resources
        if parsed_ref && parsed_ref[:type] == 'resource'
          db[:as_arclight_resource].filter(:uri => uri).delete
          db[:as_arclight_resource].insert(:uri => uri)

          out[:flagged] << uri
        else
          # but we let the client know if it wasn't to our taste
          out[:not_flagged] << uri
        end
      end

      json_response(out)
    end
  end

  Endpoint.get('/as_arclight/remove_indexing_flag')
    .description("Remove Arclight indexing flags for Resource URIs")
    .params(["uris", [String], "The Resource URIs to flag"])
    .permissions([:index_system])
    .returns([200, "success"]) \
  do
    DB.open do |db|
      out = {:unflagged => [], :not_unflagged => []}

      params[:uris].each do |uri|
        parsed_ref = JSONModel.parse_reference(uri)
        # we only flag resources
        if parsed_ref && parsed_ref[:type] == 'resource'
          db[:as_arclight_resource].filter(:uri => uri).delete

          out[:unflagged] << uri
        else
          # but we let the client know if it wasn't to our taste
          out[:not_unflagged] << uri
        end
      end

      json_response(out)
    end
  end

  Endpoint.get('/as_arclight/remove_all_indexing_flags')
    .description("Remove all Arclight indexing flags")
    .params()
    .permissions([:index_system])
    .returns([200, "success"]) \
  do
    # delete all flags

    json_response({:message => 'success'})
  end

  Endpoint.get('/as_arclight/resources_to_index')
    .description("Get all resources eligible for Arclight indexing")
    .params(["max_failures", Integer, "The maximum number of failures before giving up"])
    .permissions([:index_system])
    .returns([200, "success"]) \
  do
    out = {:uris => [], :failed => []}

    max_failures = params[:max_failures]

    DB.open do |db|
      db[:as_arclight_resource].where { failure_count > max_failures }.each do |failed_resource|
        out[:failed] << failed_resource
      end

      db[:as_arclight_resource].where { failure_count > max_failures }.delete

      eligible_resource_ds = db[:as_arclight_resource].where{(next_retry_time =~ nil) | (next_retry_time <= Time.now.to_i)}

      out[:uris] = eligible_resource_ds.select_map(:uri)

      json_response(out)
    end
  end

  Endpoint.get('/as_arclight/increment_failure_count')
    .description("Increment the failure count for a Resource URI")
    .params(["uri", String, "The Resource URI to increment"],
            ["next_retry", Integer, "Timestamp to set for next retry"])
    .permissions([:index_system])
    .returns([200, "success"]) \
  do
    DB.open do |db|
      out = {:flagged => [], :not_flagged => []}
      db[:as_arclight_resource].filter(:uri => params[:uri])
        .update(:next_retry_time => params[:next_retry],
                :failure_count => Sequel.expr(:failure_count) + 1)
    end
  end


  Endpoint.get('/as_arclight/flag_for_delete')
    .description("Flag Resource URIs for Arclight delete")
    .params(["uris", [String], "The Resource URIs to flag"])
    .permissions([:index_system])
    .returns([200, "success"]) \
  do
    DB.open do |db|
      out = {:flagged => [], :not_flagged => []}

      params[:uris].each do |uri|
        parsed_ref = JSONModel.parse_reference(uri)

        # we only flag resources
        if parsed_ref && parsed_ref[:type] == 'resource'
          db[:as_arclight_deleted_resource].filter(:uri => uri).delete
          db[:as_arclight_deleted_resource].insert(:uri => uri)

          out[:flagged] << uri
        else
          # but we let the client know if it wasn't to our taste
          out[:not_flagged] << uri
        end
      end

      json_response(out)
    end
  end

  Endpoint.get('/as_arclight/resources_to_delete')
    .description("Get all resources flagged as deleted")
    .params()
    .permissions([:index_system])
    .returns([200, "success"]) \
  do
    DB.open do |db|
      json_response(db[:as_arclight_deleted_resource].select_map(:uri))
    end
  end

  Endpoint.get('/as_arclight/remove_delete_flag')
    .description("Remove Arclight delete flag for Resource URI")
    .params(["uri", String, "The Resource URI to unflag"])
    .permissions([:index_system])
    .returns([200, "success"]) \
  do
    DB.open do |db|
      db[:as_arclight_deleted_resource].filter(:uri => uri).delete

      json_response(:message => 'success')
    end
  end

  # FIXME: these two endpoints need permissions
  #        they currently get called before the indexer logs in
  Endpoint.get('/as_arclight/index_versions')
    .description("Get Arclight index versions")
    .params()
    .permissions([])
    .returns([200, "success"]) \
  do
    DB.open do |db|
      json_response(db[:as_arclight_index_version].all)
    end
  end

  Endpoint.post('/as_arclight/index_version')
    .description("Create a new Arclight index version")
    .params(['version', Integer, "Version number"],
            ['config_hash', String, "Config settings for version"])
    .permissions([])
    .no_data(true)
    .returns([200, "success"]) \
  do
    DB.open do |db|
      db[:as_arclight_index_version].insert(:version => params[:version], :config_hash => params[:config_hash])
    end
  end



  Endpoint.get('/as_arclight/repositories/:repo_id/resources/:id')
    .description("Fetch extra summary information needed for Arclight indexing")
    .params(["id", :id],
            ["repo_id", :repo_id])
    .permissions([:index_system])
    .returns([200, "summary_data"]) \
  do
    DB.open do |db|
      out = {}
      out['_total_components'] = db[:archival_object].filter(:root_record_id => params[:id], :publish => 1).count
      out['_online_item_count'] =
        db[:instance_do_link_rlshp]
        .left_join(:digital_object, :digital_object__id => :instance_do_link_rlshp__digital_object_id)
        .left_join(:instance, :instance__id => :instance_do_link_rlshp__instance_id)
        .left_join(:archival_object, :archival_object__id => :instance__archival_object_id)
        .filter(:digital_object__publish => 1, :archival_object__publish => 1, :archival_object__root_record_id => params[:id])
        .count

      json_response(out)
    end
  end

  Endpoint.get('/as_arclight/ancestors')
    .description("Fetch ancestor fields required for mapping Archival Objects during Arclight indexing")
    .params(["id_set", [String], "IDs of Archival Object ancestors"])
    .permissions([:index_system])
    .returns([200, "ancestor_summary_data"]) \
  do
    DB.open do |db|
      json_response(db[:archival_object].filter(:id => params[:id_set])
                                        .select(:id, :ref_id, :component_id, :repo_id, :display_string)
                                        .map{|row|
                      row[:uri] = JSONModel(:archival_object).uri_for(row[:id], :repo_id => row[:repo_id])
                      row.delete(:id)
                      row.delete(:repo_id)
                      row
                    })
    end
  end
end
