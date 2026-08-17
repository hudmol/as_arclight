require_relative 'cache/null'
require_relative 'cache/sqlite'
require_relative 'cache/disk'

class IIIFClient

  class Cache
    CacheEntry = Struct.new(:url, :json, :request_time)
  end

end
