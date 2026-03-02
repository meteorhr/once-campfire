require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"

    sign_in :david
    @room = rooms(:watercooler)
    @messages = @room.messages.ordered.to_a
  end

  test "index returns the last page by default" do
    get room_messages_url(@room)

    assert_response :success
    ensure_messages_present @messages.last
  end

  test "index returns a page before the specified message" do
    get room_messages_url(@room, before: @messages.third)

    assert_response :success
    ensure_messages_present @messages.first, @messages.second
    ensure_messages_not_present @messages.third, @messages.fourth, @messages.fifth
  end

  test "index returns a page after the specified message" do
    get room_messages_url(@room, after: @messages.third)

    assert_response :success
    ensure_messages_present @messages.fourth, @messages.fifth
    ensure_messages_not_present @messages.first, @messages.second, @messages.third
  end

  test "index returns no_content when there are no messages" do
    @room.messages.destroy_all

    get room_messages_url(@room)

    assert_response :no_content
  end

  test "get renders a single message belonging to the user" do
    message = @room.messages.where(creator: users(:david)).first

    get room_message_url(@room, message)

    assert_response :success
  end

  test "creating a message broadcasts the message to the room" do
    post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "New one", client_message_id: 999 } }

    assert_rendered_turbo_stream_broadcast @room, :messages, action: "append", target: [ @room, :messages ] do
      assert_select ".message__body", text: /New one/
      assert_copy_link_button room_at_message_url(@room, Message.last, host: "once.campfire.test")
    end
  end

  test "creating a message broadcasts unread room" do
    assert_broadcasts "unread_rooms", 1 do
      post room_messages_url(@room, format: :turbo_stream), params: { message: { body: "New one", client_message_id: 999 } }
    end
  end

  test "creating an encrypted message in a direct room stores only ciphertext" do
    direct_room = rooms(:david_and_jason)
    payload = {
      "v" => 1,
      "alg" => Message::E2E_ALGORITHM,
      "from" => users(:david).id,
      "to" => users(:jason).id,
      "c" => 0,
      "iv" => "aW5pdGlhbHZlY3Rvcg",
      "ciphertext" => "Y2lwaGVydGV4dA"
    }

    post room_messages_url(direct_room, format: :turbo_stream), params: { message: {
      client_message_id: "enc-1",
      e2e_algorithm: Message::E2E_ALGORITHM,
      e2e_payload: payload.to_json
    } }

    assert_response :success

    message = Message.last
    assert message.encrypted?
    assert_equal Message::E2E_ALGORITHM, message.e2e_algorithm
    assert_equal payload["ciphertext"], message.e2e_payload_hash["ciphertext"]
    assert_equal "", message.plain_text_body
  end

  test "creating a multi-device encrypted message stores per-device envelopes" do
    direct_room = rooms(:david_and_jason)
    payload = {
      "v" => 2,
      "alg" => Message::E2E_ALGORITHM,
      "from" => users(:david).id,
      "to" => users(:jason).id,
      "from_device_id" => "dev-david-phone",
      "envelopes" => [
        {
          "sender_device_id" => "dev-david-phone",
          "recipient_device_id" => "dev-jason-laptop",
          "c" => 0,
          "iv" => "aW5pdGlhbHZlY3Rvcg",
          "ciphertext" => "Y2lwaGVydGV4dA"
        },
        {
          "sender_device_id" => "dev-david-phone",
          "recipient_device_id" => "dev-jason-phone",
          "c" => 0,
          "iv" => "c2Vjb25kLXZlY3Rvcg",
          "ciphertext" => "c2Vjb25kLWNpcGhlcnRleHQ"
        }
      ]
    }

    assert_difference -> { E2e::MessageEnvelope.count }, +2 do
      post room_messages_url(direct_room, format: :turbo_stream), params: { message: {
        client_message_id: "enc-multi-1",
        e2e_algorithm: Message::E2E_ALGORITHM,
        e2e_payload: payload.to_json
      } }
    end

    assert_response :success

    message = Message.last
    assert message.encrypted?
    assert_equal 2, message.e2e_payload_hash.fetch("envelopes").length

    envelopes = E2e::MessageEnvelope.where(client_message_id: "enc-multi-1").order(:id)
    assert_equal [ "dev-jason-laptop", "dev-jason-phone" ], envelopes.map { |envelope| envelope.recipient_device.device_id }
    assert_equal "dev-david-phone", envelopes.first.sender_device.device_id
  end

  test "creating a multi-device encrypted message rejects unknown recipient devices" do
    direct_room = rooms(:david_and_jason)
    payload = {
      "v" => 2,
      "alg" => Message::E2E_ALGORITHM,
      "from" => users(:david).id,
      "to" => users(:jason).id,
      "from_device_id" => "dev-david-phone",
      "envelopes" => [
        {
          "sender_device_id" => "dev-david-phone",
          "recipient_device_id" => "dev-jason-unknown",
          "c" => 0,
          "iv" => "aW5pdGlhbHZlY3Rvcg",
          "ciphertext" => "Y2lwaGVydGV4dA"
        }
      ]
    }

    assert_no_difference -> { Message.count } do
      post room_messages_url(direct_room, format: :turbo_stream), params: { message: {
        client_message_id: "enc-multi-2",
        e2e_algorithm: Message::E2E_ALGORITHM,
        e2e_payload: payload.to_json
      } }
    end

    assert_response :unprocessable_entity
  end

  test "creating a multi-device encrypted message accepts self-device sync envelopes" do
    direct_room = rooms(:david_and_jason)
    users(:david).e2e_devices.create!(
      device_id: "dev-david-tablet",
      name: "David Tablet",
      identity_key: "david-tablet-identity"
    )

    payload = {
      "v" => 3,
      "alg" => Message::E2E_ALGORITHM,
      "from" => users(:david).id,
      "to" => users(:jason).id,
      "from_device_id" => "dev-david-phone",
      "envelopes" => [
        {
          "sender_device_id" => "dev-david-phone",
          "recipient_user_id" => users(:jason).id,
          "recipient_device_id" => "dev-jason-laptop",
          "c" => 0,
          "iv" => "aW5pdGlhbHZlY3Rvcg",
          "ciphertext" => "Y2lwaGVydGV4dA"
        },
        {
          "sender_device_id" => "dev-david-phone",
          "recipient_user_id" => users(:david).id,
          "recipient_device_id" => "dev-david-tablet",
          "c" => 0,
          "iv" => "c2VsZi12ZWN0b3I",
          "ciphertext" => "c2VsZi1jaXBoZXJ0ZXh0"
        }
      ]
    }

    assert_difference -> { E2e::MessageEnvelope.count }, +2 do
      post room_messages_url(direct_room, format: :turbo_stream), params: { message: {
        client_message_id: "enc-multi-self-1",
        e2e_algorithm: Message::E2E_ALGORITHM,
        e2e_payload: payload.to_json
      } }
    end

    assert_response :success

    envelopes = E2e::MessageEnvelope.where(client_message_id: "enc-multi-self-1")
    assert_equal [ users(:david).id, users(:jason).id ], envelopes.map { |envelope| envelope.recipient_device.user_id }.sort
  end

  test "creating a multi-device encrypted message rejects payload without peer recipient envelope" do
    direct_room = rooms(:david_and_jason)
    users(:david).e2e_devices.create!(
      device_id: "dev-david-desktop",
      name: "David Desktop",
      identity_key: "david-desktop-identity"
    )

    payload = {
      "v" => 3,
      "alg" => Message::E2E_ALGORITHM,
      "from" => users(:david).id,
      "to" => users(:jason).id,
      "from_device_id" => "dev-david-phone",
      "envelopes" => [
        {
          "sender_device_id" => "dev-david-phone",
          "recipient_user_id" => users(:david).id,
          "recipient_device_id" => "dev-david-desktop",
          "c" => 0,
          "iv" => "c2VsZi12ZWN0b3I",
          "ciphertext" => "c2VsZi1jaXBoZXJ0ZXh0"
        }
      ]
    }

    assert_no_difference -> { Message.count } do
      post room_messages_url(direct_room, format: :turbo_stream), params: { message: {
        client_message_id: "enc-multi-self-only",
        e2e_algorithm: Message::E2E_ALGORITHM,
        e2e_payload: payload.to_json
      } }
    end

    assert_response :unprocessable_entity
  end

  test "creating an encrypted message is rejected in non-direct rooms" do
    payload = {
      "v" => 1,
      "alg" => Message::E2E_ALGORITHM,
      "from" => users(:david).id,
      "to" => users(:jason).id,
      "c" => 0,
      "iv" => "aW5pdGlhbHZlY3Rvcg",
      "ciphertext" => "Y2lwaGVydGV4dA"
    }

    post room_messages_url(@room, format: :turbo_stream), params: { message: {
      client_message_id: "enc-2",
      e2e_algorithm: Message::E2E_ALGORITHM,
      e2e_payload: payload.to_json
    } }

    assert_response :unprocessable_entity
  end

  test "update updates a message belonging to the user" do
    message = @room.messages.where(creator: users(:david)).first

    Turbo::StreamsChannel.expects(:broadcast_replace_to).once
    put room_message_url(@room, message), params: { message: { body: "Updated body" } }

    assert_redirected_to room_message_url(@room, message)
    assert_equal "Updated body", message.reload.plain_text_body
  end

  test "admin updates a message belonging to another user" do
    message = @room.messages.where(creator: users(:jason)).first

    Turbo::StreamsChannel.expects(:broadcast_replace_to).once
    put room_message_url(@room, message), params: { message: { body: "Updated body" } }

    assert_redirected_to room_message_url(@room, message)
    assert_equal "Updated body", message.reload.plain_text_body
  end

  test "destroy destroys a message belonging to the user" do
    message = @room.messages.where(creator: users(:david)).first

    assert_difference -> { Message.count }, -1 do
      Turbo::StreamsChannel.expects(:broadcast_remove_to).once
      delete room_message_url(@room, message, format: :turbo_stream)
      assert_response :success
    end
  end

  test "admin destroy destroys a message belonging to another user" do
    assert users(:david).administrator?
    message = @room.messages.where(creator: users(:jason)).first

    assert_difference -> { Message.count }, -1 do
      Turbo::StreamsChannel.expects(:broadcast_remove_to).once
      delete room_message_url(@room, message, format: :turbo_stream)
      assert_response :success
    end
  end

  test "ensure non-admin can't update a message belonging to another user" do
    sign_in :jz
    assert_not users(:jz).administrator?

    room = rooms(:designers)
    message = room.messages.where(creator: users(:jason)).first

    put room_message_url(room, message), params: { message: { body: "Updated body" } }
    assert_response :forbidden
  end

  test "ensure non-admin can't destroy a message belonging to another user" do
    sign_in :jz
    assert_not users(:jz).administrator?

    room = rooms(:designers)
    message = room.messages.where(creator: users(:jason)).first

    delete room_message_url(room, message, format: :turbo_stream)
    assert_response :forbidden
  end

  test "mentioning a bot triggers a webhook" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    assert_enqueued_jobs 1, only: Bot::WebhookJob do
      post room_messages_url(@room, format: :turbo_stream), params: { message: {
        body: "<div>Hey #{mention_attachment_for(:bender)}</div>", client_message_id: 999 } }
    end
  end

  test "encrypted messages cannot be edited" do
    direct_room = rooms(:david_and_jason)
    message = direct_room.messages.create!(
      creator: users(:david),
      client_message_id: "enc-3",
      e2e_algorithm: Message::E2E_ALGORITHM,
      e2e_payload: {
        "v" => 1,
        "alg" => Message::E2E_ALGORITHM,
        "from" => users(:david).id,
        "to" => users(:jason).id,
        "c" => 1,
        "iv" => "aW5pdGlhbHZlY3Rvcg",
        "ciphertext" => "Y2lwaGVydGV4dA"
      }
    )

    put room_message_url(direct_room, message), params: { message: { body: "Updated body" } }
    assert_response :unprocessable_entity
  end

  private
    def ensure_messages_present(*messages, count: 1)
      messages.each do |message|
        assert_select "#" + dom_id(message), count:
      end
    end

    def ensure_messages_not_present(*messages)
      ensure_messages_present *messages, count: 0
    end

    def assert_copy_link_button(url)
      assert_select ".btn[title='Copy link'][data-copy-to-clipboard-content-value='#{url}']"
    end
end
