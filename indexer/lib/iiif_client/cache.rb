class IIIFClient

  class Cache

    CacheEntry = Struct.new(:url, :json, :request_time)

    class NullCache
      def get_cache_entry(_uri)
        nil
      end

      def insert_response(uri, http_response)
        nil
      end
    end


    class SQLiteCache

      def initialize(db_path, opts)
        @connection = org.sqlite.JDBC.new.connect("jdbc:sqlite:#{db_path}", java.util.Properties.new)

        # Enable WAL
        auto_close(@connection.create_statement) do |stmt|
          stmt.execute_update("PRAGMA journal_mode=WAL")
        end

        @min_cache_seconds = opts.fetch(:min_cache_seconds, nil)

        create_schema!
      end

      def get_cache_entry(uri)
        auto_close(@connection.prepare_statement("SELECT uri, response, timestamp FROM cache WHERE uri = ? AND expiration_time > ?")) do |ps|
          ps.set_string(1, uri.to_s)
          ps.set_long(2, Time.now.to_i)
          auto_close(ps.execute_query) do |rs|
            if rs.next
              compressed = rs.get_bytes("response")
              response = decompress(compressed)
              return CacheEntry.new(rs.get_string("uri"), response, rs.get_int("timestamp"))
            else
              return nil
            end
          end
        end
      end

      def run_expiration!
        auto_close(@connection.prepare_statement("delete FROM cache WHERE expiration_time < ?")) do |ps|
          ps.set_long(1, Time.now.to_i)
          ps.execute_update
        end
      end

      def insert_response(uri, http_response)
        if rand < 0.01
          run_expiration!
        end

        json = http_response.to_json
        compressed = compress(json)

        expiration_time = http_response.cache_expiration_time.to_i

        if @min_cache_seconds
          min_expiration = (Time.now.to_i + @min_cache_seconds)
          expiration_time = [expiration_time, min_expiration].max
        end

        auto_close(@connection.prepare_statement("INSERT OR REPLACE INTO cache (uri, response, timestamp, expiration_time) VALUES (?, ?, ?, ?)")) do |ps|
          ps.set_string(1, uri.to_s)
          ps.set_bytes(2, compressed)
          ps.set_long(3, Time.now.to_i)
          ps.set_long(4, expiration_time)
          ps.execute_update
        end

        CacheEntry.new(uri.to_s, json, Time.now.to_i)
      end

      def close
        @connection.close
      end

      private

      def compress(string)
        out_bytes = java.io.ByteArrayOutputStream.new

        gzip = java.util.zip.GZIPOutputStream.new(out_bytes)
        gzip.write(string.to_java_bytes)
        gzip.close

        out_bytes.to_byte_array
      end

      def decompress(gzip_bytes)
        in_bytes = java.io.ByteArrayInputStream.new(gzip_bytes)
        out_bytes = java.io.ByteArrayOutputStream.new

        gzip = java.util.zip.GZIPInputStream.new(in_bytes)

        buf = Java::byte[4096].new

        while ((len = gzip.read(buf, 0, buf.length)) >= 0)
          out_bytes.write(buf, 0, len)
        end

        gzip.close

        java.lang.String.new(out_bytes.to_byte_array,
                             java.nio.charset.StandardCharsets::UTF_8)
      end

      def auto_close(*closeables, &block)
        begin
          block.call(*closeables)
        ensure
          closeables.each(&:close)
        end
      end

      def create_schema!
        auto_close(@connection.create_statement) do |stmt|
          stmt.execute_update("CREATE TABLE IF NOT EXISTS cache (" +
                              "  uri TEXT PRIMARY KEY," +
                              "  response BLOB," +
                              "  timestamp INTEGER," +
                              "  expiration_time INTEGER" +
                              ")")

          stmt.execute_update("CREATE INDEX IF NOT EXISTS idx_cache_expiration_time ON cache (expiration_time)")
        end
      end
    end

  end

end
