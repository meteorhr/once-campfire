class Accounts::SlackImportsController < ApplicationController
  before_action :ensure_can_administer
  before_action :ensure_slack_import_token, only: %i[ channels users create ]

  # Step 1: Upload form
  def new
  end

  # Step 1 submit: Validate ZIP, store temp file, redirect to channels
  def upload
    archive = params.dig(:slack_import, :archive)
    return redirect_to(new_account_slack_import_url, alert: "Choose a Slack export ZIP file.") if archive.blank?

    token = SecureRandom.hex
    tmp_dir = Rails.root.join("tmp", "slack_imports", token)
    FileUtils.mkdir_p(tmp_dir)

    zip_path = tmp_dir.join("archive.zip")
    FileUtils.cp(archive.tempfile.path, zip_path)

    parsed = Slack::Archive.new(zip_path).parse

    unless parsed.valid?
      FileUtils.rm_rf(tmp_dir)
      return redirect_to(new_account_slack_import_url, alert: "This doesn't look like a Slack export ZIP.")
    end

    File.write(tmp_dir.join("metadata.json"), { channels: parsed.channels, users: parsed.users }.to_json)

    session[:slack_import_token] = token

    redirect_to channels_account_slack_import_url
  rescue Slack::Archive::InvalidArchiveError => e
    redirect_to new_account_slack_import_url, alert: e.message
  end

  # Step 2: Channel mapping table
  def channels
    metadata = load_metadata
    @slack_channels = metadata["channels"]
    @campfire_rooms = Room.opens.ordered
  end

  # Step 3: User mapping table (receives channel mappings via params)
  def users
    channel_mappings = params[:channel_mappings]&.to_unsafe_h || {}
    save_channel_mappings(channel_mappings)

    metadata = load_metadata
    @slack_users = metadata["users"].select { |u| u.is_a?(Hash) && u["id"].present? }
    @campfire_users = User.active.ordered
  end

  # Final import
  def create
    user_mappings = params[:user_mappings]&.to_unsafe_h || {}
    channel_mappings = load_channel_mappings

    result = Slack::Import.new(
      archive: File.open(archive_path),
      importer: Current.user,
      channel_mappings: channel_mappings,
      user_mappings_hash: user_mappings
    ).call

    cleanup_import_files

    redirect_to edit_account_url, notice: "Imported #{result.messages_imported} messages into #{result.rooms_touched} rooms."
  rescue Slack::Import::InvalidArchiveError, Slack::Import::InvalidMappingsError => e
    redirect_to new_account_slack_import_url, alert: e.message
  end

  private
    def import_dir
      Rails.root.join("tmp", "slack_imports", session[:slack_import_token])
    end

    def archive_path
      import_dir.join("archive.zip")
    end

    def load_metadata
      JSON.parse(File.read(import_dir.join("metadata.json")))
    end

    def save_channel_mappings(mappings)
      File.write(import_dir.join("channel_mappings.json"), mappings.to_json)
    end

    def load_channel_mappings
      path = import_dir.join("channel_mappings.json")
      File.exist?(path) ? JSON.parse(File.read(path)) : {}
    end

    def ensure_slack_import_token
      redirect_to new_account_slack_import_url unless session[:slack_import_token].present? && File.exist?(archive_path)
    end

    def cleanup_import_files
      FileUtils.rm_rf(import_dir)
      session.delete(:slack_import_token)
    end
end
