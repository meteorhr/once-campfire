require "zip"

class Slack::Archive
  class InvalidArchiveError < StandardError; end

  CHANNEL_FOLDER_PATTERN = %r{\A(?<channel>[^/]+)/\d{4}-\d{2}-\d{2}\.json\z}

  attr_reader :channels, :users

  def initialize(path)
    @path = path
  end

  def parse
    Zip::File.open(@path) do |zip|
      @users = parse_optional_json(zip, "users.json")
      @channels = extract_channels(zip)
    end

    self
  rescue Zip::Error
    raise InvalidArchiveError, "Could not read Slack export ZIP."
  end

  def valid?
    @channels.present?
  end

  private
    def extract_channels(zip)
      channel_entries = parse_optional_json(zip, "channels.json") + parse_optional_json(zip, "groups.json")

      folder_names = zip.entries
        .select { |e| e.file? && e.name.match?(CHANNEL_FOLDER_PATTERN) }
        .map { |e| e.name.match(CHANNEL_FOLDER_PATTERN)[:channel] }
        .uniq

      channels_from_json = channel_entries.filter_map do |ch|
        next unless ch.is_a?(Hash) && ch["id"].present?
        { "id" => ch["id"], "name" => ch["name"] }
      end

      json_channel_names = channels_from_json.map { |ch| ch["name"].downcase }.to_set

      folder_only_channels = folder_names.reject { |name| json_channel_names.include?(name.downcase) }.map do |name|
        { "id" => name, "name" => name }
      end

      channels_from_json + folder_only_channels
    end

    def parse_optional_json(zip, name)
      entry = zip.find_entry(name)
      return [] unless entry

      parsed = JSON.parse(entry.get_input_stream.read)
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      raise InvalidArchiveError, "Slack export contains invalid JSON in #{name}."
    end
end
