require 'json'
require 'pp'

class ArclightMapper

  def self.resolves
    []
  end

  def initialize(json)
    @json = json
    @map = {}
  end

  def map
    self
  end

  def map_field(field, mapped, &block)
    if block_given?
      @map[field] = block.call
    else
      @map[field] = mapped
    end
  end

  def json
    @map.to_json
  end

  def dump
    pp ['XXXXXXXXXXXXXXXXXXXXXXXXX',
        @map,
        'XXXXXXXXXXXXXXXXXXXXXXXXX']
  end
end
