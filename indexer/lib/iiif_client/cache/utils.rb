class IIIFClient
  class Cache

    class Utils

      def self.compress(string)
        out_bytes = java.io.ByteArrayOutputStream.new

        gzip = java.util.zip.GZIPOutputStream.new(out_bytes)
        gzip.write(string.to_java_bytes)
        gzip.close

        out_bytes.to_byte_array
      end

      def self.decompress(gzip_bytes)
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

    end

  end
end
