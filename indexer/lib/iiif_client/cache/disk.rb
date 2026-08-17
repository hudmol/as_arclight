require 'digest/sha1'

class IIIFClient
  class Cache
    class DiskCache
      def initialize(cache_path, opts)
        @cache_path = cache_path

        @min_cache_seconds = opts.fetch(:min_cache_seconds, nil)

        @lock = Mutex.new
      end

      def get_cache_entry(uri)
        @lock.synchronize do
          cache_path = path_for_uri(uri)

          json = begin
                       compressed = File.read(cache_path)
                       cache_entry = IIIFClient::Cache::Utils.decompress(compressed.to_java_bytes)
                       JSON.parse(cache_entry)
                     rescue Errno::ENOENT
                       return nil
                     rescue Java::JavaUtilZip::ZipException
                       ARCLog.error "Failure decompressing cache entry '#{cache_path}': #{$!}"
                       File.unlink(cache_path)
                       return nil
                     rescue
                       ARCLog.error "Unexpected error reading cache entry '#{cache_path}': #{$!}"
                       return nil
                     end


          if Integer(json.fetch('expiration_time')) < Time.now.to_i
            # Expired!
            File.unlink(cache_path)
            return nil
          else
            return CacheEntry.new(json.fetch("uri"), json.fetch("response"), json.fetch("timestamp"))
          end
        end
      end

      def insert_response(uri, http_response)
        @lock.synchronize do
          expiration_time = http_response.cache_expiration_time.to_i

          if @min_cache_seconds
            min_expiration = (Time.now.to_i + @min_cache_seconds)
            expiration_time = [expiration_time, min_expiration].max
          end

          timestamp = Time.now.to_i

          encoded_response = http_response.to_json

          compressed = IIIFClient::Cache::Utils.compress({
                                                           uri: uri,
                                                           response: encoded_response,
                                                           timestamp: timestamp,
                                                           expiration_time: expiration_time
                                                         }.to_json)

          cache_path = path_for_uri(uri)

          FileUtils.mkdir_p(File.dirname(cache_path))

          File.write(cache_path + ".tmp", compressed)
          File.rename(cache_path + ".tmp", cache_path)

          CacheEntry.new(uri.to_s, encoded_response, timestamp)
        end
      end

      def flush
      end

      def path_for_uri(uri)
        key = Digest::SHA1.hexdigest(uri.to_s)

        File.join(@cache_path, key[0...2], key[2...4], "#{key}.dat.gz")
      end

    end
  end
end
