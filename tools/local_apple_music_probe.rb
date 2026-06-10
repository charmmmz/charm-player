#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "json"
require "net/http"
require "optparse"
require "rexml/document"
require "set"
require "uri"

SONOS_PORT = 1400
APPLE_MUSIC_LOCAL_SID = 204
DEFAULT_LIMIT = 5

class SoapFault < StandardError
  attr_reader :code, :description, :raw

  def initialize(code, description, raw)
    @code = code
    @description = description
    @raw = raw
    super("#{description} (code #{code})")
  end
end

def escape_xml(value)
  CGI.escapeHTML(value.to_s)
end

def deep_unescape(value, passes: 4)
  result = value.to_s
  passes.times do
    decoded = CGI.unescapeHTML(result)
    break if decoded == result

    result = decoded
  end
  result
end

def redact(value)
  text = value.to_s.dup
  text.gsub!(/(X_#Svc\d+-)([^<\s"']+?)(-Token)/i, '\1[redacted]\3')
  text.gsub!(/(<(?:token|key|privateKey|authToken|sessionId)>)(.*?)(<\/(?:token|key|privateKey|authToken|sessionId)>)/im,
             '\1[redacted]\3')
  text.gsub!(/((?:token|key|privateKey|authToken|sessionId)=)([^&\s"']+)/i, '\1[redacted]')
  text
end

def extract_tag(xml, tag)
  escaped = Regexp.escape(tag)
  match = xml.to_s.match(%r{<#{escaped}(?:\s[^>]*)?>(.*?)</#{escaped}>}m)
  match && match[1]
end

def extract_local_tag(xml, tag)
  escaped = Regexp.escape(tag)
  match = xml.to_s.match(%r{<(?:[\w.-]+:)?#{escaped}(?:\s[^>]*)?>(.*?)</(?:[\w.-]+:)?#{escaped}>}m)
  match && match[1]
end

def http_request(uri, method: "GET", headers: {}, body: nil, timeout: 12)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = timeout
  http.read_timeout = timeout
  request_class = method == "POST" ? Net::HTTP::Post : Net::HTTP::Get
  request = request_class.new(uri)
  headers.each { |key, value| request[key] = value }
  request.body = body if body
  http.request(request)
end

def sonos_url(ip, path)
  URI("http://#{ip}:#{SONOS_PORT}#{path}")
end

def upnp_envelope(service, action, body)
  <<~XML
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
      <s:Body>
        <u:#{action} xmlns:u="urn:schemas-upnp-org:service:#{service}:1">
          #{body}
        </u:#{action}>
      </s:Body>
    </s:Envelope>
  XML
end

def upnp_soap(ip, path:, service:, action:, body: "", timeout: 12)
  response = http_request(
    sonos_url(ip, path),
    method: "POST",
    timeout: timeout,
    headers: {
      "Content-Type" => "text/xml; charset=utf-8",
      "SOAPACTION" => "\"urn:schemas-upnp-org:service:#{service}:1##{action}\""
    },
    body: upnp_envelope(service, action, body)
  )
  text = response.body.to_s
  if text.include?("<s:Fault>") || text.include?("UPnPError")
    raise SoapFault.new(
      extract_tag(text, "errorCode") || response.code,
      extract_tag(text, "errorDescription") || response.message,
      text
    )
  end
  text
end

def smapi_envelope(action, body, credentials: nil)
  header = if credentials
             login_token = if credentials[:token].to_s.empty? || credentials[:key].to_s.empty?
                             ""
                           else
                             <<~XML
                               <loginToken>
                                 <token>#{escape_xml(credentials[:token])}</token>
                                 <key>#{escape_xml(credentials[:key])}</key>
                                 <householdId>#{escape_xml(credentials[:household_id])}</householdId>
                               </loginToken>
                             XML
                           end
             <<~XML
               <s:Header>
                 <credentials xmlns="http://www.sonos.com/Services/1.1">
                   <deviceId>#{escape_xml(credentials[:device_id])}</deviceId>
                   <deviceProvider>Sonos</deviceProvider>
                   #{login_token}
                 </credentials>
               </s:Header>
             XML
           else
             ""
           end

  <<~XML
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
      s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
      #{header}
      <s:Body>
        <#{action} xmlns="http://www.sonos.com/Services/1.1">
          #{body}
        </#{action}>
      </s:Body>
    </s:Envelope>
  XML
end

def smapi_soap(endpoint, action, body, credentials: nil)
  uri = URI(endpoint)
  response = http_request(
    uri,
    method: "POST",
    timeout: 18,
    headers: {
      "Content-Type" => "text/xml; charset=utf-8",
      "SOAPACTION" => "\"http://www.sonos.com/Services/1.1##{action}\"",
      "X-Sonos-Corr-Id" => "local-probe-#{Time.now.to_i}",
      "X-Sonos-Controller-ID" => "charm-local-probe"
    },
    body: smapi_envelope(action, body, credentials: credentials)
  )
  response
end

def parse_services(xml)
  # The service descriptor is escaped exactly once by the UPnP response. Do not
  # deep-unescape here: service manifest URLs can contain escaped ampersands in
  # attributes, and expanding those makes the descriptor invalid XML.
  decoded = CGI.unescapeHTML(extract_tag(xml, "AvailableServiceDescriptorList") || "")
  services = []
  REXML::Document.new(decoded).elements.each("//Service") do |node|
    attrs = node.attributes
    services << {
      id: attrs["Id"].to_i,
      name: attrs["Name"],
      version: attrs["Version"],
      uri: attrs["Uri"],
      secure_uri: attrs["SecureUri"],
      capabilities: attrs["Capabilities"]
    }
  end
  services
rescue REXML::ParseException
  []
end

def list_services(ip)
  xml = upnp_soap(
    ip,
    path: "/MusicServices/Control",
    service: "MusicServices",
    action: "ListAvailableServices"
  )
  [parse_services(xml), extract_tag(xml, "AvailableServiceTypeList").to_s]
end

def browse_favorites(ip)
  body = "<ObjectID>FV:2</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag>" \
         "<Filter>*</Filter><StartingIndex>0</StartingIndex><RequestedCount>100</RequestedCount>" \
         "<SortCriteria></SortCriteria>"
  xml = upnp_soap(
    ip,
    path: "/MediaServer/ContentDirectory/Control",
    service: "ContentDirectory",
    action: "Browse",
    body: body
  )
  deep_unescape(extract_tag(xml, "Result") || "")
rescue SoapFault
  ""
end

def device_id(ip)
  response = http_request(sonos_url(ip, "/xml/device_description.xml"), timeout: 8)
  udn = extract_tag(response.body.to_s, "UDN").to_s.sub(/^uuid:/, "")
  udn.empty? ? nil : udn
rescue StandardError
  nil
end

def household_id(ip)
  xml = upnp_soap(
    ip,
    path: "/DeviceProperties/Control",
    service: "DeviceProperties",
    action: "GetHouseholdID"
  )
  extract_tag(xml, "CurrentHouseholdID")
rescue StandardError
  nil
end

def parse_local_apple_binding(didl, local_sid: APPLE_MUSIC_LOCAL_SID)
  decoded = deep_unescape(didl)
  sns = decoded.scan(/[?&]sid=#{local_sid}(?:&amp;|&)flags=\d+(?:&amp;|&)sn=([^&<"']+)/i).flatten
  sns.concat(decoded.scan(/[?&]sid=#{local_sid}(?:&amp;|&)sn=([^&<"']+)/i).flatten)
  descs = decoded.scan(/SA_RINCON(\d+)_([^<"']+)/i)
  apple_desc = descs.find { |cloud_sid, _username| cloud_sid.to_i != local_sid } || descs.first
  {
    account_id: sns.map { |sn| CGI.unescapeHTML(sn) }.find { |sn| !sn.empty? },
    cloud_service_id: apple_desc && apple_desc[0],
    username: apple_desc && CGI.unescapeHTML(apple_desc[1])
  }
end

def itunes_search(term, country:, limit:)
  uri = URI("https://itunes.apple.com/search")
  uri.query = URI.encode_www_form(
    media: "music",
    entity: "song",
    term: term,
    country: country,
    limit: limit
  )
  response = http_request(uri, timeout: 15)
  payload = JSON.parse(response.body)
  payload.fetch("results", [])
end

def build_track_uri(track_id, local_sid:, account_id:)
  "x-sonos-http:song%3a#{track_id}.mp4?sid=#{local_sid}&flags=8232&sn=#{account_id}"
end

def build_track_metadata(item, uri, local_sid:, account_id:, cloud_service_id:, username:)
  title = item.fetch("trackName", "Unknown")
  artist = item.fetch("artistName", "")
  album = item.fetch("collectionName", "")
  art = item["artworkUrl100"].to_s.sub("100x100bb", "600x600bb")
  object_id = "song%3a#{item.fetch("trackId")}"
  desc_user = username && !username.empty? ? username : "X_#Svc#{cloud_service_id}-#{account_id}-Token"
  desc = "SA_RINCON#{cloud_service_id}_#{desc_user}"

  "<DIDL-Lite xmlns:dc=\"http://purl.org/dc/elements/1.1/\" " \
    "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" " \
    "xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" " \
    "xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">" \
    "<item id=\"10032028#{object_id}\" parentID=\"\" restricted=\"true\">" \
    "<dc:title>#{escape_xml(title)}</dc:title>" \
    "<upnp:class>object.item.audioItem.musicTrack</upnp:class>" \
    "<upnp:albumArtURI>#{escape_xml(art)}</upnp:albumArtURI>" \
    "<dc:creator>#{escape_xml(artist)}</dc:creator>" \
    "<r:albumArtist>#{escape_xml(artist)}</r:albumArtist>" \
    "<upnp:album>#{escape_xml(album)}</upnp:album>" \
    "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">#{escape_xml(desc)}</desc>" \
    "<res protocolInfo=\"sonos.com-http:*:audio/mp4:*\">#{escape_xml(uri)}</res>" \
    "</item></DIDL-Lite>"
end

def try_smapi_search(service, term, credentials: nil)
  endpoint = service[:secure_uri].to_s.empty? ? service[:uri] : service[:secure_uri]
  body = "<id>tracks</id><term>#{escape_xml(term)}</term><index>0</index><count>#{DEFAULT_LIMIT}</count>"
  response = smapi_soap(endpoint, "search", body, credentials: credentials)
  xml = response.body.to_s
  fault = extract_local_tag(xml, "faultstring") || extract_local_tag(xml, "detail")
  sonos_error = extract_local_tag(xml, "SonosError")
  count = xml.scan(/<mediaMetadata\b/).length + xml.scan(/<mediaCollection\b/).length
  {
    endpoint: endpoint,
    http_status: response.code,
    sonos_error: sonos_error,
    fault: fault && redact(deep_unescape(fault)),
    result_count: count,
    raw: redact(xml)
  }
rescue StandardError => e
  { endpoint: endpoint, error: "#{e.class}: #{e.message}" }
end

def play_first(ip, item, binding, local_sid:)
  uri = build_track_uri(item.fetch("trackId"), local_sid: local_sid, account_id: binding[:account_id])
  metadata = build_track_metadata(
    item,
    uri,
    local_sid: local_sid,
    account_id: binding[:account_id],
    cloud_service_id: binding[:cloud_service_id],
    username: binding[:username]
  )

  upnp_soap(
    ip,
    path: "/MediaRenderer/AVTransport/Control",
    service: "AVTransport",
    action: "SetAVTransportURI",
    timeout: 30,
    body: "<InstanceID>0</InstanceID><CurrentURI>#{escape_xml(uri)}</CurrentURI>" \
          "<CurrentURIMetaData>#{escape_xml(metadata)}</CurrentURIMetaData>"
  )
  upnp_soap(
    ip,
    path: "/MediaRenderer/AVTransport/Control",
    service: "AVTransport",
    action: "Play",
    timeout: 30,
    body: "<InstanceID>0</InstanceID><Speed>1</Speed>"
  )
end

options = {
  country: "us",
  limit: DEFAULT_LIMIT,
  local_sid: APPLE_MUSIC_LOCAL_SID,
  play_first: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby tools/local_apple_music_probe.rb --speaker 192.168.50.238 --query \"john mayer\""
  parser.on("--speaker IP", "Sonos speaker IP address") { |value| options[:speaker] = value }
  parser.on("--query TERM", "Search term") { |value| options[:query] = value }
  parser.on("--country CODE", "iTunes Search API country, default: us") { |value| options[:country] = value }
  parser.on("--limit N", Integer, "Result limit, default: #{DEFAULT_LIMIT}") { |value| options[:limit] = value }
  parser.on("--local-sid N", Integer, "Local Apple Music service id, default: #{APPLE_MUSIC_LOCAL_SID}") do |value|
    options[:local_sid] = value
  end
  parser.on("--play-first", "Actually set transport URI and play the first iTunes candidate") do
    options[:play_first] = true
  end
end.parse!

speaker = options[:speaker] || ENV["SONOS_SPEAKER"]
query = options[:query] || ENV["APPLE_MUSIC_QUERY"] || "john mayer"
abort "Missing --speaker IP (or SONOS_SPEAKER)" if speaker.to_s.empty?

puts "Local Apple Music probe"
puts "speaker=#{speaker} query=#{query.inspect} localSid=#{options[:local_sid]}"

services, type_list = list_services(speaker)
apple = services.find { |service| service[:id] == options[:local_sid] } ||
        services.find { |service| service[:name].to_s.downcase.include?("apple") }

unless apple
  puts "Apple Music service not found. Available services:"
  services.each { |service| puts "  sid=#{service[:id]} name=#{service[:name]}" }
  exit 2
end

puts "\n[1] Local service"
puts "  sid=#{apple[:id]} name=#{apple[:name]} version=#{apple[:version]} capabilities=#{apple[:capabilities]}"
puts "  endpoint=#{apple[:secure_uri].to_s.empty? ? apple[:uri] : apple[:secure_uri]}"
puts "  raw service type list=#{type_list.empty? ? "(empty)" : type_list}"
detected_device_id = device_id(speaker)
detected_household_id = household_id(speaker)
puts "  deviceId=#{detected_device_id || "(not found)"} householdId=#{detected_household_id || "(not found)"}"

favorites = browse_favorites(speaker)
binding = parse_local_apple_binding(favorites, local_sid: options[:local_sid])
binding[:cloud_service_id] ||= "52231"

puts "\n[2] Local binding inferred from speaker content"
puts "  accountId(sn)=#{binding[:account_id] || "(not found)"}"
puts "  cloudServiceId=#{binding[:cloud_service_id] || "(not found)"}"
puts "  usernameTemplate=#{redact(binding[:username] || "(not found)")}"

puts "\n[3] Direct Apple Music SMAPI search without Sonos Cloud login"
smapi = try_smapi_search(apple, query)
if smapi[:error]
  puts "  no credentials: failed=#{smapi[:error]}"
elsif smapi[:fault]
  puts "  no credentials: http=#{smapi[:http_status]} sonosError=#{smapi[:sonos_error] || "(none)"} fault=#{smapi[:fault]}"
else
  puts "  no credentials: http=#{smapi[:http_status]} resultCount=#{smapi[:result_count]}"
end

if detected_device_id
  device_only = try_smapi_search(
    apple,
    query,
    credentials: {
      device_id: detected_device_id,
      household_id: detected_household_id
    }
  )
  if device_only[:error]
    puts "  device header only: failed=#{device_only[:error]}"
  elsif device_only[:fault]
    puts "  device header only: http=#{device_only[:http_status]} sonosError=#{device_only[:sonos_error] || "(none)"} fault=#{device_only[:fault]}"
  else
    puts "  device header only: http=#{device_only[:http_status]} resultCount=#{device_only[:result_count]}"
  end
end

puts "\n[4] Non-MusicKit catalog search via iTunes Search API"
items = itunes_search(query, country: options[:country], limit: options[:limit])
if items.empty?
  puts "  no iTunes results"
else
  items.each_with_index do |item, index|
    track_id = item["trackId"]
    title = item["trackName"]
    artist = item["artistName"]
    album = item["collectionName"]
    puts "  #{index + 1}. #{title} - #{artist} / #{album} (trackId=#{track_id})"
    if binding[:account_id]
      puts "     sonosURI=#{build_track_uri(track_id, local_sid: options[:local_sid], account_id: binding[:account_id])}"
    else
      puts "     sonosURI=(missing local Apple Music accountId/sn)"
    end
  end
end

if options[:play_first]
  abort "\nCannot play: missing local Apple Music accountId/sn" unless binding[:account_id]
  abort "\nCannot play: no iTunes result" if items.empty?

  puts "\n[5] Playback"
  play_first(speaker, items.first, binding, local_sid: options[:local_sid])
  puts "  sent SetAVTransportURI + Play for: #{items.first["trackName"]} - #{items.first["artistName"]}"
else
  puts "\n[5] Playback"
  puts "  skipped. Re-run with --play-first to test real playback."
end
