require 'sequel'
require 'json'
require 'tempfile'

require_relative '../indexer/lib/sqlite-jdbc-3.53.0.0.jar'

def load_hierarchy(db, file_id, record, ancestors = [])
  if record.is_a?(Hash)
    if record['id']
      if ancestors.last
        db[:hierarchy].insert(file_id: file_id, parent_id: ancestors.last, child_id: record['id'])
      end

      ancestors << record['id']
      record.values.each do |v|
        load_hierarchy(db, file_id, v, ancestors)
      end
      ancestors.pop
    end
  elsif record.is_a?(Array)
    record.each do |v|
      load_hierarchy(db, file_id, v, ancestors)
    end
  end
end


def load_record_values(db, file_id, record)
  raise record.inspect unless record.is_a?(Hash)

  id = record.fetch('id')

  record.each do |field, value|
    next if field == 'components'
    db[:record_value].insert(file_id: file_id, record_id: id, key: field, value: JSON.dump(value))
  end

  record.fetch('components', []).each do |subrecord|
    load_record_values(db, file_id, subrecord)
  end
end

def compare_files(old_file, new_file)
  dbfile = Tempfile.new

  Sequel.connect("jdbc:sqlite:#{dbfile.path}") do |db|
    db.create_table(:hierarchy) do
      primary_key :id
      String :file_id
      String :parent_id
      String :child_id
    end

    db.create_table(:record_value) do
      primary_key :id
      String :file_id
      String :record_id
      String :key
      Blob :value
    end

    db.add_index(:hierarchy, [:file_id, :parent_id, :child_id])
    db.add_index(:hierarchy, [:file_id, :child_id])
    db.add_index(:record_value, [:file_id, :record_id, :key])

    [["old", old_file], ["new", new_file]].each do |file, path|
      content = File.read(path)
      content = '[]' if content.empty?

      records = JSON.parse(content)

      load_hierarchy(db, file, records)

      records.each do |record|
        load_record_values(db, file, record)
      end
    end

    ## Compare hierarchy
    db[:hierarchy].filter(file_id: "old").each do |old_parent_child|
      if db[:hierarchy]
           .filter(file_id: "new")
           .filter(parent_id: old_parent_child.fetch(:parent_id))
           .filter(child_id: old_parent_child.fetch(:child_id))
           .count == 0
        puts "Record only in pristine: #{old_parent_child}"
      end
    end

    db[:hierarchy].filter(file_id: "new").each do |new_parent_child|
      if db[:hierarchy]
           .filter(file_id: "old")
           .filter(parent_id: new_parent_child.fetch(:parent_id))
           .filter(child_id: new_parent_child.fetch(:child_id))
           .count == 0
        puts "Record only in candidate: #{new_parent_child}"
      end
    end


    ## Compare values
    db[:record_value].filter(file_id: "old").each do |old_record_value|
      if db[:hierarchy].filter(parent_id: old_record_value.fetch(:record_id)).filter(file_id: "new").count == 0 &&
         db[:hierarchy].filter(child_id: old_record_value.fetch(:record_id)).filter(file_id: "new").count == 0
        # Already failed the hierarchy check
        next
      end

      matched_row = db[:record_value]
                      .filter(file_id: "new")
                      .filter(record_id: old_record_value.fetch(:record_id))
                      .filter(key: old_record_value.fetch(:key))
                      .first

      if !matched_row
        puts "Record #{old_record_value.fetch(:record_id)} key missing value in candidate: #{old_record_value.fetch(:key)}"
        next
      end

      old_value = JSON.parse(old_record_value.fetch(:value))
      new_value = JSON.parse(matched_row.fetch(:value))

      if old_value != new_value
        puts "Record #{old_record_value.fetch(:record_id)} has mismatch in value for key #{old_record_value.fetch(:key)}:"

        puts "Pristine value: #{old_value}"
        puts "Candidate value: #{new_value}"
      end
    end

    db[:record_value].filter(file_id: "new").each do |new_record_value|
      if db[:hierarchy].filter(parent_id: new_record_value.fetch(:record_id)).filter(file_id: "old").count == 0 &&
         db[:hierarchy].filter(child_id: new_record_value.fetch(:record_id)).filter(file_id: "old").count == 0
        # Already failed the hierarchy check
        next
      end

      matched_row = db[:record_value]
                      .filter(file_id: "old")
                      .filter(record_id: new_record_value.fetch(:record_id))
                      .filter(key: new_record_value.fetch(:key))
                      .first

      if !matched_row
        puts "Record #{new_record_value.fetch(:record_id)} key missing value in pristine: #{new_record_value.fetch(:key)}"
        next
      end
    end
  end
end

def main
  if ARGV.length != 2
    $stderr.puts("Usage: diff_json.sh <pristine> <candidate>")
    $stderr.puts("")
    $stderr.puts("Arguments can either be two files or two directories")
    exit(1)
  end

  old_path = ARGV.fetch(0)
  new_path = ARGV.fetch(1)

  if Dir.exist?(old_path)
    old_path = Dir.glob(File.join(old_path, "*.json"))
  end

  if Dir.exist?(new_path)
    new_path = Dir.glob(File.join(new_path, "*.json"))
  end

  if old_path.class != new_path.class
    $stderr.puts("Pristine and Candidate arguments need to be the same type (either both files or both directories)")
    exit(1)
  end

  if old_path.is_a?(String)
    compare_files(old_path, new_path)
    exit
  end

  old_paths = old_path.sort_by {|f| File.basename(f)}
  new_paths = new_path.sort_by {|f| File.basename(f)}

  loop do
    break if old_paths.empty? && new_paths.empty?

    if old_paths.empty?
      new_paths.each do |path|
        puts "File only appeared in candidate and was not checked: #{path}"
      end

      break
    end

    if new_paths.empty?
      old_paths.each do |path|
        puts "File only appeared in pristine and was not checked: #{path}"
      end

      break
    end

    if File.basename(old_paths[0]) == File.basename(new_paths[0])
      compare_files(old_paths[0], new_paths[0])
      old_paths.shift
      new_paths.shift
    elsif File.basename(old_paths[0]) < File.basename(new_paths[0])
      puts "File only appeared in pristine and was not checked: #{old_paths[0]}"
      old_paths.shift
    else
      puts "File only appeared in candidate and was not checked: #{new_paths[0]}"
      new_paths.shift
    end
  end

end


main
