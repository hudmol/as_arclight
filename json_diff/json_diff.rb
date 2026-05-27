require 'sequel'
require 'json'
require 'tempfile'

require_relative '../indexer/lib/sqlite-jdbc-3.53.0.0.jar'

# Read current terminal width into MAX_WIDTH
ENV['COLUMNS'] ||= `tput cols 2>/dev/null`.strip rescue ''

MAX_WIDTH = Integer(ENV.fetch('COLUMNS', '80'))

def record_id(record, dflt = :raise)
  result = if dflt == :raise
    record.fetch('id')
  else
    record.fetch('id', dflt)
  end

  result
end

def load_hierarchy(db, file_id, record, ancestors = [])
  if record.is_a?(Hash)
    if record_id(record, nil)
      if ancestors.last
        db[:hierarchy].insert(file_id: file_id, parent_id: ancestors.last, child_id: record_id(record))
      end

      ancestors << record_id(record)
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

  id = record_id(record)

  record.each do |field, value|
    next if field == 'components'
    db[:record_value].insert(file_id: file_id, record_id: id, key: field, value: JSON.dump(value))
  end

  record.fetch('components', []).each do |subrecord|
    load_record_values(db, file_id, subrecord)
  end
end

def puts_truncated(s)
  puts s[0...MAX_WIDTH]
end

def compare_files(args, old_file, new_file)
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
        puts "\n-Parent/child relationship only in #{args.pristine_label}: parent=#{old_parent_child.fetch(:parent_id)} child=#{old_parent_child.fetch(:child_id)}"
      end
    end

    db[:hierarchy].filter(file_id: "new").each do |new_parent_child|
      if db[:hierarchy]
           .filter(file_id: "old")
           .filter(parent_id: new_parent_child.fetch(:parent_id))
           .filter(child_id: new_parent_child.fetch(:child_id))
           .count == 0
        puts "\n+Parent/child relationship only in #{args.candidate_label}: parent=#{new_parent_child.fetch(:parent_id)} child=#{new_parent_child.fetch(:child_id)}"
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
        if old_record_value.fetch(:value) != '[]'
          puts "\n--- Record #{old_record_value.fetch(:record_id)} field missing in #{args.candidate_label}: '#{old_record_value.fetch(:key)}'"
          puts_truncated("-Sample from #{args.pristine_label}: #{old_record_value.fetch(:value)}")
          puts_truncated("+(missing from #{args.candidate_label})")
        end

        next
      end

      old_value = old_record_value.fetch(:value)
      new_value = matched_row.fetch(:value)

      if old_value != new_value
        puts "\n--- Record #{old_record_value.fetch(:record_id)} has mismatch in value for field '#{old_record_value.fetch(:key)}':"

        mismatch_char = (0..[old_value.length, new_value.length].min).find {|i| old_value[i] != new_value[i]}

        ellipses = "... "

        context_size = (MAX_WIDTH / 2) - ellipses.length

        context_start = [0, mismatch_char - context_size].max

        old_substring = old_value[context_start...]
        new_substring = new_value[context_start...]

        offset = context_start

        if context_start > 0
          old_substring = "#{ellipses}#{old_substring}"
          new_substring = "#{ellipses}#{new_substring}"

          offset -= ellipses.length
        end

        puts_truncated("-#{args.pristine_label} snippet:  #{old_substring}")
        candidate_prefix = "#{args.candidate_label} snippet: "
        puts_truncated("+#{candidate_prefix}#{new_substring}")
        puts (" " * candidate_prefix.length ) + (" " * (mismatch_char - offset + 1)) + "^ character #{mismatch_char + 1}"
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
        if new_record_value.fetch(:value) != '[]'
          puts "\n--- Record #{new_record_value.fetch(:record_id)} field missing in #{args.pristine_label}: '#{new_record_value.fetch(:key)}'"
          puts_truncated("-(missing from #{args.pristine_label}): #{new_record_value.fetch(:value)}")
          puts_truncated("+Sample from #{args.candidate_label}: #{new_record_value.fetch(:value)}")
        end

        next
      end
    end
  end
end

Args = Struct.new(:old_path, :new_path, :pristine_alias, :candidate_alias) do
  def candidate_label
    self.candidate_alias
  end

  def pristine_label
    self.pristine_alias
  end
end


def process_commandline
  result = Args.new

  args = ARGV.clone
  positionals = []

  while args.length > 0
    if args[0] == '-h' || args[0] == '--help'
      return nil
    end

    if args[0].start_with?('--')
      option = args.shift

      if option =~ /=/
        (option, rest) = option.split('/', 2)
        args.unshift(rest)
      end

      case option
      when "--pristine-alias"
        result.pristine_alias = args.shift
      when "--candidate-alias"
        result.candidate_alias = args.shift
      else
        $stderr.puts("Unknown argument: #{option}")
        return nil
      end
    else
      positionals << args.shift
    end
  end

  result.candidate_alias ||= 'candidate'
  result.pristine_alias ||= 'pristine'

  if positionals.length == 2
    result.old_path, result.new_path = positionals
  else
    return nil
  end

  result
end

def main
  args = process_commandline

  unless args
    $stderr.puts("Usage: diff_json.sh <pristine file/dir> <candidate file/dir>")
    $stderr.puts("")
    $stderr.puts("Available options:")
    $stderr.puts("")
    $stderr.puts(sprintf("  %-30s -- %s", "--pristine-alias [name]", "Refer to 'pristine' as 'name' instead"))
    $stderr.puts(sprintf("  %-30s -- %s", "--candidate-alias [name]", "Refer to 'candidate' as 'name' instead"))
    $stderr.puts("")

    exit(1)
  end

  old_path = args.old_path
  new_path = args.new_path

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
    compare_files(args, old_path, new_path)
    exit
  end

  old_paths = old_path.sort_by {|f| File.basename(f)}
  new_paths = new_path.sort_by {|f| File.basename(f)}

  loop do
    break if old_paths.empty? && new_paths.empty?

    if old_paths.empty?
      new_paths.each do |path|
        puts "\nFile only appeared in #{args.candidate_label} and was not checked: #{path}"
      end

      break
    end

    if new_paths.empty?
      old_paths.each do |path|
        puts "\nFile only appeared in #{args.pristine_label} and was not checked: #{path}"
      end

      break
    end

    if File.basename(old_paths[0]) == File.basename(new_paths[0])
      compare_files(old_paths[0], new_paths[0])
      old_paths.shift
      new_paths.shift
    elsif File.basename(old_paths[0]) < File.basename(new_paths[0])
      puts "\nFile only appeared in #{args.pristine_label} and was not checked: #{old_paths[0]}"
      old_paths.shift
    else
      puts "\nFile only appeared in #{args.candidate_label} and was not checked: #{new_paths[0]}"
      new_paths.shift
    end
  end

end


main
