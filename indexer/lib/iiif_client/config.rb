require_relative 'cache'
require_relative 'extractors'

class IIIFClient

  class Config
    def request_cache
      @cache_instance ||= IIIFClient::Cache::SQLiteCache.new("/tmp/iiif_cache.db")
    end

    def configure_http(_http)
    end

    def configure_http_request(_http, _request)
    end

    def extractor_for_rendering(rendering)
      if rendering.type == 'Text' && rendering.format == 'text/plain'
        IIIFClient::Extractors::TextExtractor.new
      elsif rendering.type == 'Text' && rendering.format == 'text/vnd.hocr+html'
        IIIFClient::Extractors::HOCRExtractor.new
      else
        nil
      end
    end

    def parser_for_version(iiif_version, _manifest_json)
      if iiif_version == 3
        V3Parser.new
      else
        V2Parser.new
      end
    end

    def request_timeout_seconds
      300
    end

    def max_request_retries
      5
    end

    def max_request_retry_interval_seconds
      30
    end

    def max_redirects
      10
    end

    def log(level, s)
      $stderr.puts(sprintf("[%s] %s", level, s))
    end
  end

end
