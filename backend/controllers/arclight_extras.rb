class ArchivesSpaceService < Sinatra::Base

  Endpoint.get('/repositories/:repo_id/resources/:id/arclight_extras')
    .description("Fetch extra summary information needed for ArcLight indexing")
    .params(["id", :id],
            ["repo_id", :repo_id])
    .permissions([:view_repository])
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
end
