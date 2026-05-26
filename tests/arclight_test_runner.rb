archivesspace_dir = ARGV.fetch(0)

ENV['GEM_HOME'] = ENV['GEM_PATH'] = File.join(archivesspace_dir, 'build', 'gems', 'jruby', Gem.ruby_api_version)

Gem.clear_paths

$LOAD_PATH << File.join(archivesspace_dir, 'common')
$LOAD_PATH << File.join(archivesspace_dir, 'indexer', 'app', 'lib')

require 'periodic_indexer'
require_relative '../indexer/lib/arclight_indexer'

require 'active_support/all'
require 'rspec'


Dir.glob(File.join(File.dirname(__FILE__), "spec/*_spec.rb")).each do |spec|
  require spec
end

RSpec::Core::Runner.run([])
