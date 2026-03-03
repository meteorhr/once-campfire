require "test_helper"

class RoomsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "index redirects to the user's last room" do
    get rooms_url
    assert_redirected_to room_url(users(:david).rooms.last)
  end

  test "show" do
    get room_url(users(:david).rooms.last)
    assert_response :success
  end

  test "show direct room includes phase 2 e2e onboarding endpoints" do
    room = rooms(:david_and_jason)
    self_prekey_url = user_e2e_prekey_bundle_path(user_id: "me", room_id: room.id, self_sync: true)

    get room_url(room)

    assert_response :success
    assert_select "form#composer[data-composer-e2e-enabled-value='true']"
    assert_select "form#composer[data-composer-e2e-device-url-value='#{user_e2e_device_path}']"
    assert_select "form#composer[data-composer-e2e-peer-user-id-value='#{users(:jason).id}']"
    assert_select "form#composer[data-composer-e2e-prekey-bundle-url-value='#{user_e2e_prekey_bundle_path(users(:jason), room_id: room.id)}']"
    assert_select "form#composer[data-composer-e2e-self-prekey-bundle-url-value='#{self_prekey_url}']"
  end

  test "shows records the last room visited in a cookie" do
    get room_url(users(:david).rooms.last)
    assert response.cookies[:last_room] = users(:david).rooms.last.id
  end

  test "destroy" do
    assert_turbo_stream_broadcasts :rooms, count: 1 do
      assert_difference -> { Room.count }, -1 do
        delete room_url(rooms(:designers))
      end
    end
  end

  test "destroy only allowed for creators or those who can administer" do
    sign_in :jz

    assert_no_difference -> { Room.count } do
      delete room_url(rooms(:designers))
      assert_response :forbidden
    end

    rooms(:designers).update! creator: users(:jz)

    assert_difference -> { Room.count }, -1 do
      delete room_url(rooms(:designers))
    end
  end
end
