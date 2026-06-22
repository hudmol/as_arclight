class IndexVersion

  @borking_config = [:as_arclight_resource_id_prefix,
                     :as_arclight_archival_object_id_delimiter]

  @version
  @reindex_required = false

  def self.version
    @version
  end

  def self.reindex_required?
    @reindex_required
  end

  def self.generate_index_version_hash
    @borking_config.map{|bc| [bc, AppConfig[bc]]}.to_h.to_json
  end

  def self.ensure_config!
    unless AppConfig.has_key?(:as_arclight_index_version)
      ARCLog.info "Applying default - AppConfig[:as_arclight_index_version] = 1"
      AppConfig[:as_arclight_index_version] = 1
    end
    unless AppConfig.has_key?(:as_arclight_resource_id_prefix)
      ARCLog.info "Applying default - AppConfig[:as_arclight_resource_id_prefix] = ''"
      AppConfig[:as_arclight_resource_id_prefix] = ''
    end
    unless AppConfig.has_key?(:as_arclight_archival_object_id_delimiter)
      ARCLog.info "Applying default - AppConfig[:as_arclight_archival_object_id_delimiter] = '_'"
      AppConfig[:as_arclight_archival_object_id_delimiter] = '_'
    end

    @version = AppConfig[:as_arclight_index_version]
  end

  def self.validate_config_or_die!(db)
    ensure_config!

    ARCLog.info "Checking index version #{version}"

    if db[:index_version].count == 0
      ARCLog.info "Initializing index version #{version}"
      ARCLog.debug "No reindex required - this is the first index version for this deployment"
      db[:index_version].insert(:version => version, :config_hash => generate_index_version_hash)
    else
      current_index_version = db[:index_version].order(:version).select_all.last
      if version == current_index_version[:version]
        if generate_index_version_hash == current_index_version[:config_hash]
          ARCLog.info "Index version #{version} validated"
          ARCLog.debug "No reindex required - the current version has been validated"
        else
          parsed_hash = JSON.parse(current_index_version[:config_hash])

          revert_message = ''

          if (new_config = (@borking_config - parsed_hash.keys.map(&:intern))).empty?
            revert_message = "    To stay on the current index version, revert config to:\n" +
                             parsed_hash.map{|k,v| "        AppConfig[:#{k}] = '#{v}'"}.join("\n")
          else
            revert_message = "    You are running a new version of the plugin that has additional config requirements: #{new_config.join(', ')}\n" +
                             "    If you want to stay on your current index version, you need to revert your plugin version to one compatible with your index"
          end

          ARCLog.error "Index version config mismatch!\n" +
            ("*" * 100) + "\n" +
            "    Increment AppConfig[:as_arclight_index_version] to #{version + 1} and restart to trigger a full reindex.\n" +
            revert_message +
            "\n" + ("*" * 100) + "\n"

          raise "as_arclight index version mismatch"
        end
      elsif version < current_index_version[:version]
        ARCLog.error "Index AppConfig[:as_arclight_index_version] cannot decrease! Current version: #{current_index_version[:version]}. Attempt to set to #{version}"
        raise "as_arclight invalid index version"
      else
        ARCLog.info "Initializing index version #{version}. Full reindex required"
        db[:index_version].insert(:version => version, :config_hash => generate_index_version_hash)
        @reindex_required = true
      end
    end
  end
end
