require 'sequel'

class ARCDB
  def initialize(data_dir, opts = {})
    @data_dir_path = File.join(data_dir, 'arclight_indexer.db')
    @local_path = '/tmp/as_arclight_working_copy_of_indexer.db'
    @connection_count = java.util.concurrent.atomic.AtomicInteger.new(0)

    if File.exist?(@local_path)
      File.rm(@local_path)
      ARCLog.warn "Removed unexpected local copy. Did we have an unexpected shutdown?"
    end
  end

  def ensure_prepared
    unless File.exist?(@data_dir_path)
      ARCLog.info 'Initializing db at ' + @data_dir_path
    end

    connect do |db|
      db.run("PRAGMA journal_mode = WAL;")
      init_schema(db)
    end
  end

  def ensure_local
    if File.exist?(@local_path)
      true
    else
      copy_to_local_dir
      false
    end
  end

  def copy_to_local_dir
    if File.exist?(@local_path)
      raise "as_arclight plugin: Attempt to copy database file to a local directory when it is already there!"
    else
      if File.exist?(@data_dir_path)
        FileUtils.cp(@data_dir_path, @local_path)
        ARCLog.debug "Database file copied to local directory for access"
      else
        ARCLog.debug "Creating new database file for access"
      end
    end
  end

  def restore_to_data_dir
    if @connection_count.get > 0
      raise "as_arclight plugin: Attempt to restore database file while there are open connections!"
    else
      FileUtils.mv(@local_path, @data_dir_path)
      ARCLog.debug "Database file restored to data directory"
    end
  end

  def connect
    already_local = ensure_local
    conn = Sequel.connect("jdbc:sqlite:#{@local_path}")
    @connection_count.incrementAndGet
    yield conn
  ensure
    conn.disconnect
    @connection_count.decrementAndGet
    restore_to_data_dir unless already_local
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
