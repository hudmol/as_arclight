class ArchivesSpaceService < Sinatra::Base

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
