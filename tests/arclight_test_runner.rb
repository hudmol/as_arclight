require 'tempfile'
require 'fileutils'

begin
  require 'simplecov'

  SimpleCov.start do
    root File.absolute_path(File.join(File.dirname(__FILE__), ".."))
    add_filter '/spec/'
    add_filter 'indexer/plugin_init.rb'
  end
rescue LoadError
  $stderr.puts "SimpleCov gem was not available.  Line coverage reporting will not be available."
  $stderr.puts ""
  $stderr.puts "To make this work, point your ARCHIVESSPACE environment variable to a clone of."
  $stderr.puts "the ArchivesSpace git repository that has been bootstrapped with `build/run bootstrap`"
  $stderr.puts ""
end

TEST_DATA_DIR = '/tmp/as_arclight_test_data'
ENV['APPCONFIG_DATA_DIRECTORY'] = TEST_DATA_DIR
FileUtils.rm_rf(TEST_DATA_DIR)
FileUtils.mkdir_p(TEST_DATA_DIR)

archivesspace_dir = ENV.fetch('ARCHIVESSPACE')

$LOAD_PATH << File.join(archivesspace_dir, 'common')
$LOAD_PATH << File.join(archivesspace_dir, 'indexer', 'app', 'lib')

begin
  require 'periodic_indexer'
rescue LoadError => e
  $stderr.puts("")
  $stderr.puts("NOTE: We have failed to load our dependencies.")
  $stderr.puts("These tests need to be run from a git clone of ArchivesSpace that has been bootstrapped with `build/run bootstrap`")
  $stderr.puts("")

  raise e
end

require 'log'
require_relative '../indexer/lib/arclog'
require_relative '../indexer/lib/ead_helper'
require_relative File.join(File.dirname(__FILE__), '../indexer/lib/sqlite-jdbc-3.53.0.0.jar')
require_relative '../indexer/lib/arclight_indexer'
ArclightIndexer.ensure_data_dir_or_die!

require 'active_support/all'
require 'rspec'

$ARCLIGHT_UNIT_TESTS = true


RSpec.configure do |config|
  config.order = :defined

  config.before(:each) do
    # Ensure some AppConfig entries don't pollute our tests
    allow(AppConfig).to receive(:has_key?).and_call_original
    allow(AppConfig).to receive(:[]).and_call_original

    {
      :as_arclight_solr_targets => [{:url => "http://solr.example/core"}],
      :as_arclight_indexing_frequency_seconds => 30,
      :as_arclight_index_version => 1,
      :as_arclight_resource_id_prefix => '',
      :as_arclight_archival_object_id_delimiter => '_',
      :as_arclight_reset_queue_on_start => false,
      :disable_config_changed_warning => true,
    }.each do |config_entry, setting|
      allow(AppConfig).to receive(:has_key?).with(config_entry).and_return(true)
      allow(AppConfig).to receive(:[]).with(config_entry).and_return(setting)
    end
  end
end

Dir.glob(File.join(File.dirname(__FILE__), "spec/*_spec.rb")).sort_by {|f| File.basename(f)}.each do |spec|
  require spec
end

RSpec::Core::Runner.run([])
