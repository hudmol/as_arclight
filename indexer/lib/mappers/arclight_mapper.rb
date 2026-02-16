require 'json'

class ArclightMapper

  def self.resolves
    []
  end

  def initialize(json)
    @json = json
    @map = {}

    self.map
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
end
