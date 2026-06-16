require 'base64'
require 'json'
require 'net/http'
require 'nokogiri'
require 'uri'

require_relative 'iiif_client/config'
require_relative 'iiif_client/errors'
require_relative 'iiif_client/v2_parser'
require_relative 'iiif_client/v3_parser'

class IIIFClient

  attr_reader :config

  def initialize(config)
    @config = config
  end

  def fetch_manifest(url)
    Log.debug "as_arclight plugin: Fetching manifest from URL: #{url}"

    response = fetch_url(url, config.max_redirects)

    if response.is_success?
      content_type = response.content_type

      unless content_type.include?('/json')
        raise Errors::ManifestParseFailed.new("Expected a JSON response, but got '#{content_type}'")
      end

      json = begin
               JSON.parse(response.body)
             rescue Exception => e
               raise Errors::ManifestParseFailed.new("JSON parse error: '#{e}'")
             end

      iiif_version = nil

      if json.fetch('@context').to_s =~ %r{/3/}
        iiif_version = 3
      elsif json.fetch('@context').to_s =~ %r{/2/} || json.fetch('@type', '').to_s.downcase == 'sc:manifest'
        iiif_version = 2
      else
        raise Errors::UnknownManifestVersion.new
      end

      parser = config.parser_for_version(iiif_version, json)

      Manifest.from_hash(
        version: iiif_version,
        metadata: parser.parse_metadata(json),
        renderings: select_renderings_of_interest(json, parser),
        annotations: select_annotations(json, parser),
        json: json
      )
    else
      raise Errors::HTTPError.new(
              "Unexpected HTTP response (status=%s; url=%s)" % [response.status, url],
              response
            )
    end
  end

  ExtractRenderingTextResult = Struct.new(:successful, :rendering, :response, :text, :error) do
    def is_success?
      self.successful
    end
  end

  def extract_rendering_text(renderings)
    renderings.each do |rendering|
      extractor = config.extractor_for_rendering(rendering)

      if extractor.nil?
        next
      end

      response = fetch_url(rendering.url, config.max_redirects)

      if response.is_success?
        body_text = response.body

        content_type = response.headers.fetch('content-type', []).first

        # Best-effort to use the right encoding here.
        if content_type && content_type =~ /charset\s*=\s*"?([^\s";]+)"?/i
          encoding = $1

          begin
            body_text.force_encoding(encoding)
          rescue
          end
        end

        yield ExtractRenderingTextResult.new(true, rendering, response, extractor.extract(body_text), nil)
      else
        error = Errors::HTTPError.new(
          "Unexpected HTTP response (status=%s; url=%s)" % [response.status, rendering.url],
          response
        )

        yield ExtractRenderingTextResult.new(false, rendering, response, nil, error)
      end
    end
  end


  HTTPResponse = Struct.new(:status, :headers, :body) do

    def self.from_net_http_response(response)
      HTTPResponse.new(response.code.to_s, response.to_hash, response.body)
    end

    def to_json
      mapped = members.map {|attr| [attr.to_s, self[attr]]}.to_h
      mapped['body'] = Base64.encode64(mapped['body'])

      JSON.dump(mapped)
    end

    def self.from_json(json)
      parsed = JSON.parse(json)

      parsed['body'] = Base64.decode64(parsed['body'])

      HTTPResponse.new(parsed.fetch('status'), parsed.fetch('headers'), parsed.fetch('body'))
    end

    def is_success?
      self.status =~ /^2/
    end

    def content_type
      self.headers.fetch('content-type', []).fetch(0, 'application/octet-stream')
    end

    def cache_expiration_time
      now = Time.now

      cache_control = self.headers.fetch('cache-control', []).first

      if cache_control
        if cache_control =~ /max-age\s*=\s*(\d+)/i
          return now + Integer($1)
        end

        if cache_control =~ /no-cache|no-store/i
          return now - 1
        end
      end

      expires = self.headers.fetch('expires', []).first

      if expires
        begin
          return Time.parse(expires)
        rescue
        end
      end

      now - 1
    end

  end

  module StructFromHash
    def from_hash(h)
      result = self.new

      members.each do |member|
        result[member] = h[member.to_s] || h[member]
      end

      result
    end
  end

  Manifest = Struct.new(:version, :metadata, :renderings, :annotations, :json) do
    extend StructFromHash
  end

  IIIFMetadata = Struct.new(:label, :value) do
    extend StructFromHash
  end

  IIIFText = Struct.new(:language, :value)

  IIIFRendering = Struct.new(:type, :format, :url, :labels, :profile) do
    extend StructFromHash
  end

  IIIFAnnotation = Struct.new(:id, :type, :motivation, :body, :target) do
    extend StructFromHash
  end

  TreeItem = Struct.new(:path, :item) do
    def path_str
      path.map {|elt| elt.is_a?(String) ? path : '[%s]' % [path]}.join('/')
    end
  end


  private


  def fetch_url(url, redirects_remaining = 1, original_url = nil)
    if redirects_remaining == 0
      raise Errors::MaxRedirectsHit.new
    end

    url = URI.parse(url.to_s)

    cache_entry = config.request_cache.get_cache_entry(url)

    if cache_entry
      return HTTPResponse.from_json(cache_entry.json)
    end

    Log.debug "as_arclight plugin: Fetching URL #{url}"

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = (url.scheme == 'https')
    http.read_timeout = config.request_timeout_seconds
    http.open_timeout = config.request_timeout_seconds
    http.max_retries = 0

    config.configure_http(http)
    request = Net::HTTP::Get.new(url)
    config.configure_http_request(http, request)

    response = nil
    last_error = nil
    config.max_request_retries.times do |retry_count|
      begin
        response = http.request(request)
        break
      rescue Exception => e
        last_error = e

        if (retry_count + 1) < config.max_request_retries
          Log.warn "as_arclight plugin: Failure during HTTP request - GET #{url}: #{e}." +
                   "  Will retry (attempt #{retry_count + 1} of #{config.max_request_retries})"
          sleep [2 ** (retry_count + 1), config.max_request_retry_interval_seconds].min
        end
      end
    end

    if response.nil?
      Log.error "as_arclight plugin: Permanent failure during HTTP request - GET #{url}: #{last_error}"
      return HTTPResponse.new('499', {}, "Request failure: #{last_error}")
    end

    case response
    when Net::HTTPRedirection
      next_url = URI.parse(response['location'])
      return fetch_url(next_url, redirects_remaining - 1, (original_url || url))
    else
      result = HTTPResponse.from_net_http_response(response)

      if result.is_success?
        config.request_cache.insert_response((original_url || url), result)
      end

      result
    end
  end

  def select_renderings_of_interest(tree, parser, results = [], path_to_root = [])
    if tree.is_a?(Hash)
      if parser.possible_rendering?(path_to_root, tree) && (rendering = parser.parse_rendering(tree))
        results << TreeItem.new(path_to_root, rendering)
      else
        tree.keys.each do |k|
          select_renderings_of_interest(tree.fetch(k), parser, results, path_to_root + [k])
        end
      end

    elsif tree.is_a?(Array)
      tree.each_with_index do |elt, idx|
        select_renderings_of_interest(elt, parser, results, path_to_root + [idx])
      end
    end

    results
  end

  def select_annotations(tree, parser, results = [], path_to_root = [])
    if tree.is_a?(Hash)
      if parser.possible_annotation?(path_to_root, tree) && (annotation = parser.parse_annotation(tree))
        results << TreeItem.new(path_to_root, annotation)
      else
        tree.keys.each do |k|
          select_annotations(tree.fetch(k), parser, results, path_to_root + [k])
        end
      end

    elsif tree.is_a?(Array)
      tree.each_with_index do |elt, idx|
        select_annotations(elt, parser, results, path_to_root + [idx])
      end
    end

    results
  end

end
