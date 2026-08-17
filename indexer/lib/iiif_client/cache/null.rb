class IIIFClient

  class Cache
    class NullCache
      def get_cache_entry(_uri)
        nil
      end

      def insert_response(_uri, _http_response)
        nil
      end

      def flush
      end
    end
  end

end
