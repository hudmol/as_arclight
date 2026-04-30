class IIIFClient

  class Errors
    class UnknownManifestVersion < StandardError; end
    class ManifestParseFailed < StandardError; end
    class MaxRedirectsHit < StandardError; end
    class NoExtractorAvailable < StandardError; end
    class HTTPError < StandardError
      attr_reader :response

      def initialize(msg, response = nil)
        super(msg)
        @response = response
      end
    end
  end

end
