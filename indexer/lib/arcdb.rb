require 'sequel'
require 'securerandom'

class ARCDB
  def initialize(data_dir, opts = {})
    @data_dir_path = File.join(data_dir, 'arclight_indexer.db')

    ARCLog.info 'Opened db at ' + @data_dir_path

    # There's only ever one thread touching SQLite at a time, so we only allow
    # one connection and fail immediately if a second comes along.
    @db = Sequel.connect("jdbc:sqlite:#{@data_dir_path}",
                         max_connections: 1,
                         pool_timeout: 0,
                         connect_sqls: [
                           "PRAGMA busy_timeout = 10000"
                         ])

    @db.synchronize do
      @db.run("PRAGMA journal_mode = WAL")
      init_schema(@db)
    end
  end

  def transaction
    @db.transaction do
      yield @db
    end
  end

  def init_schema(db)
    db.create_table?(:resource) do
      primary_key :id
      String :uri, :null => false, :unique => true
    end

    db.create_table?(:deleted_resource) do
      primary_key :id
      String :uri, :null => false, :unique => true
    end

    # start with a fresh document table
    db.drop_table?(:document)

    db.create_table(:document) do
      primary_key :id
      String :resource_uri
      Integer :parent_id
      blob :json
    end

    unless db[:resource].columns.include?(:next_retry_time)
      db.alter_table(:resource) do
        add_column :next_retry_time, :Bignum
      end
    end

    unless db[:resource].columns.include?(:failure_count)
      db.alter_table(:resource) do
        add_column :failure_count, :Bignum, :default => 0
      end
    end

    db.create_table?(:index_version) do
      primary_key :id
      Integer :version, :null => false, :unique => true
      String :config_hash, :null => false, :text => true
    end
  end
end
