require 'sequel'
require 'securerandom'

class ARCDB
  def initialize(data_dir, opts = {})
    @data_dir_path = File.join(data_dir, 'arclight_indexer.db')

    @session_active = java.util.concurrent.atomic.AtomicBoolean.new(false)

    ensure_prepared
  end

  def ensure_prepared
    unless File.exist?(@data_dir_path)
      ARCLog.info 'Initializing db at ' + @data_dir_path
    end

    with_session do
      transaction do |db|
        db.run("PRAGMA journal_mode = WAL;")
        init_schema(db)
      end
    end
  end

  SESSION_LOCK = java.util.concurrent.locks.ReentrantLock.new

  # Copy the SQLite DB from the ArchivesSpace data directory to a local temp
  # file in anticipation of updating it.  Once updates complete, copy it back.
  def with_session
    SESSION_LOCK.lock

    if SESSION_LOCK.getHoldCount > 1
      begin
        yield
      ensure
        SESSION_LOCK.unlock
      end
    else
      @session_active.set(true)
      begin
        copy_to_local_dir
        yield
      ensure
        restore_to_data_dir
        @session_active.set(false)
        SESSION_LOCK.unlock
      end
    end
  end

  def copy_to_local_dir
    @tmpfile = Tempfile.new('arclight_indexer_working_copy.db')
    @local_path = @tmpfile.path

    if File.exist?(@data_dir_path)
      FileUtils.cp(@data_dir_path, @local_path)
      ARCLog.debug "Database file copied to local directory for access"
    else
      ARCLog.debug "Creating new database file for access"
    end
  end

  def restore_to_data_dir
    FileUtils.mv(@local_path, @data_dir_path + ".tmp")
    FileUtils.mv(@data_dir_path + ".tmp", @data_dir_path)
    ARCLog.debug "Database file restored to data directory"
  end

  def transaction
    unless @session_active.get
      raise "Can only call ArcDB#transaction from within an ArcDB#session block"
    end

    conn = Sequel.connect("jdbc:sqlite:#{@local_path}")
    yield conn
  ensure
    conn.disconnect if conn
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
