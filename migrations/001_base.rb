Sequel.migration do
  up do
    create_table(:as_arclight_resource) do
      primary_key :id
      String :uri, :null => false
      Integer :failure_count, :null => false, :default => 0
      column :next_retry_time, :Bignum
    end

    create_table(:as_arclight_deleted_resource) do
      primary_key :id
      String :uri, :null => false
    end

    create_table(:as_arclight_index_version) do
      primary_key :id
      Integer :version, :null => false, :unique => true
      String :config_hash, :null => false
    end
  end
end
