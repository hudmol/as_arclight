require 'tempfile'
require 'fileutils'

require 'simplecov'

SimpleCov.start do
  root File.absolute_path(File.join(File.dirname(__FILE__), ".."))
  add_filter '/spec/'
  add_filter 'indexer/plugin_init.rb'
end

FileUtils.mkdir_p(ENV['APPCONFIG_DATA_DIRECTORY'] = '/tmp/as_arclight_test_data')

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

RSpec::Core::Runner.run([])
