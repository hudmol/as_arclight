require 'tempfile'
require 'fileutils'

require 'simplecov'

SimpleCov.start do
  root File.absolute_path(File.join(File.dirname(__FILE__), ".."))
  add_filter '/spec/'
  add_filter 'indexer/plugin_init.rb'
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
require_relative '../indexer/lib/arclight_indexer'

require 'active_support/all'
require 'rspec'


Dir.glob(File.join(File.dirname(__FILE__), "spec/*_spec.rb")).each do |spec|
  require spec
end

$ARCLIGHT_UNIT_TESTS = true


RSpec.configure do |config|
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
    }.each do |config_entry, setting|
      allow(AppConfig).to receive(:has_key?).with(config_entry).and_return(true)
      allow(AppConfig).to receive(:[]).with(config_entry).and_return(setting)
    end
  end
end

RSpec::Core::Runner.run([])
