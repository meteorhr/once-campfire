require "test_helper"
require "zip"

class Accounts::SlackImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "new shows upload form" do
    get new_account_slack_import_url
    assert_response :ok
  end

  test "upload validates archive is present" do
    post upload_account_slack_import_url, params: { slack_import: {} }
    assert_redirected_to new_account_slack_import_url
    assert_equal "Choose a Slack export ZIP file.", flash[:alert]
  end

  test "upload validates archive is a slack export" do
    empty_zip = Tempfile.new([ "empty", ".zip" ])
    Zip::File.open(empty_zip.path, create: true) { |zip| zip.get_output_stream("random.txt") { |s| s.write("hello") } }

    post upload_account_slack_import_url, params: {
      slack_import: { archive: Rack::Test::UploadedFile.new(empty_zip.path, "application/zip") }
    }
    assert_redirected_to new_account_slack_import_url
    assert_equal "This doesn't look like a Slack export ZIP.", flash[:alert]
  ensure
    empty_zip&.close!
  end

  test "upload parses zip and redirects to channels step" do
    with_slack_export_upload(slack_export_entries) do |archive|
      post upload_account_slack_import_url, params: { slack_import: { archive: archive } }
    end

    assert_redirected_to channels_account_slack_import_url
  end

  test "channels step shows channel mapping table" do
    setup_slack_import_session

    get channels_account_slack_import_url
    assert_response :ok
  end

  test "channels step redirects to new without session" do
    get channels_account_slack_import_url
    assert_redirected_to new_account_slack_import_url
  end

  test "users step stores channel mappings and shows user mapping table" do
    setup_slack_import_session

    get users_account_slack_import_url, params: {
      channel_mappings: { "general" => { "selected" => "1", "room" => "new" } }
    }
    assert_response :ok
  end

  test "full wizard flow creates rooms and imports messages" do
    setup_slack_import_session

    # Step 2 -> Step 3: pass channel mappings
    get users_account_slack_import_url, params: {
      channel_mappings: { "general" => { "selected" => "1", "room" => "new" } }
    }
    assert_response :ok

    # Step 3 -> Import: pass user mappings
    assert_difference -> { Room.opens.count }, +1 do
      assert_difference -> { Message.count }, +2 do
        post account_slack_import_url, params: {
          user_mappings: { "U1" => users(:david).id.to_s }
        }
      end
    end

    assert_redirected_to edit_account_url

    room = Room.opens.find_by!(name: "general")
    imported_messages = room.messages.ordered.last(2)

    assert_equal users(:david), imported_messages.first.creator
    assert_equal "Hey @David", imported_messages.first.body.to_plain_text

    # Unmapped user messages are attributed to the importer
    assert_equal users(:david), imported_messages.second.creator
    assert_equal "[Robot] Imported by bot", imported_messages.second.body.to_plain_text
  end

  test "full wizard flow maps channel to existing room" do
    existing_room = Room.create_for({ name: "general", type: "Rooms::Open", creator: users(:david) }, users: User.active)
    setup_slack_import_session

    get users_account_slack_import_url, params: {
      channel_mappings: { "general" => { "selected" => "1", "room" => existing_room.id.to_s } }
    }

    assert_no_difference -> { Room.opens.count } do
      assert_difference -> { Message.count }, +2 do
        post account_slack_import_url, params: { user_mappings: {} }
      end
    end

    assert_equal 2, existing_room.messages.count
  end

  test "creating new channel adds _slack suffix when name already exists" do
    Room.create_for({ name: "general", type: "Rooms::Open", creator: users(:david) }, users: User.active)
    setup_slack_import_session

    get users_account_slack_import_url, params: {
      channel_mappings: { "general" => { "selected" => "1", "room" => "new" } }
    }

    assert_difference -> { Room.opens.count }, +1 do
      post account_slack_import_url, params: { user_mappings: {} }
    end

    assert Room.opens.find_by(name: "general_slack")
  end

  test "creating new channel with custom name" do
    setup_slack_import_session

    get users_account_slack_import_url, params: {
      channel_mappings: { "general" => { "selected" => "1", "room" => "new", "new_name" => "my-general" } }
    }

    assert_difference -> { Room.opens.count }, +1 do
      post account_slack_import_url, params: { user_mappings: {} }
    end

    assert Room.opens.find_by(name: "my-general")
  end

  test "unselected channels are skipped" do
    setup_slack_import_session

    get users_account_slack_import_url, params: {
      channel_mappings: { "general" => { "room" => "new" } }
    }

    assert_no_difference -> { Message.count } do
      post account_slack_import_url, params: { user_mappings: {} }
    end
  end

  test "non-admins cannot access any step" do
    sign_in :kevin

    get new_account_slack_import_url
    assert_response :forbidden

    post upload_account_slack_import_url, params: { slack_import: {} }
    assert_response :forbidden
  end

  private
    def setup_slack_import_session
      with_slack_export_upload(slack_export_entries) do |archive|
        post upload_account_slack_import_url, params: { slack_import: { archive: archive } }
      end
    end

    def with_slack_export_upload(entries)
      archive = Tempfile.new([ "slack-export", ".zip" ])

      Zip::File.open(archive.path, create: true) do |zip|
        entries.each do |name, content|
          zip.get_output_stream(name) { |stream| stream.write(content) }
        end
      end

      yield Rack::Test::UploadedFile.new(archive.path, "application/zip")
    ensure
      archive&.close!
    end

    def slack_export_entries
      {
        "users.json" => [
          { id: "U1", name: "david", real_name: "David", profile: { email: users(:david).email_address } },
          { id: "U2", name: "robot", real_name: "Robot" }
        ].to_json,
        "channels.json" => [ { id: "C1", name: "general" } ].to_json,
        "general/2024-03-18.json" => [
          { type: "message", user: "U1", text: "Hey <@U1>", ts: "1710000000.000001" },
          { type: "message", username: "Robot", text: "Imported by bot", ts: "1710000001.000002" }
        ].to_json
      }
    end
end
