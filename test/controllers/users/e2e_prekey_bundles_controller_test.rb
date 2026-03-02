require "test_helper"

class Users::E2ePrekeyBundlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show returns multi-device prekey bundle and consumes one-time prekeys" do
    laptop_prekey = e2e_one_time_prekeys(:jason_one)
    phone_prekey = e2e_one_time_prekeys(:jason_phone_one)

    assert_nil laptop_prekey.consumed_at
    assert_nil phone_prekey.consumed_at

    get user_e2e_prekey_bundle_url(user_id: users(:jason).id, format: :json)

    assert_response :success

    payload = JSON.parse(response.body)
    assert_equal users(:jason).id, payload.dig("user", "id")
    assert_equal 2, payload.fetch("devices").length
    assert_equal [ "dev-jason-laptop", "dev-jason-phone" ], payload.fetch("devices").map { |device| device.fetch("device_id") }.sort
    assert_equal [ 4001, 4101 ], payload.fetch("devices").map { |device| device.dig("one_time_prekey", "key_id") }.sort
    assert laptop_prekey.reload.consumed_at.present?
    assert phone_prekey.reload.consumed_at.present?
  end

  test "show does not consume one-time prekey for known devices" do
    laptop_prekey = e2e_one_time_prekeys(:jason_one)
    phone_prekey = e2e_one_time_prekeys(:jason_phone_one)

    get user_e2e_prekey_bundle_url(user_id: users(:jason).id, known_device_ids: "dev-jason-laptop", format: :json)

    assert_response :success

    payload = JSON.parse(response.body)
    laptop_bundle = payload.fetch("devices").find { |device| device.fetch("device_id") == "dev-jason-laptop" }
    phone_bundle = payload.fetch("devices").find { |device| device.fetch("device_id") == "dev-jason-phone" }

    assert_nil laptop_bundle["one_time_prekey"]
    assert_equal 4101, phone_bundle.dig("one_time_prekey", "key_id")
    assert_nil laptop_prekey.reload.consumed_at
    assert phone_prekey.reload.consumed_at.present?
  end

  test "show returns forbidden when users are not in a direct room" do
    get user_e2e_prekey_bundle_url(user_id: users(:bender).id, format: :json)

    assert_response :forbidden
  end

  test "show returns forbidden when room_id is not a shared direct room" do
    get user_e2e_prekey_bundle_url(user_id: users(:jason).id, room_id: rooms(:watercooler).id, format: :json)

    assert_response :forbidden
  end

  test "show rejects self bundle fetch" do
    get user_e2e_prekey_bundle_url(user_id: "me", format: :json)

    assert_response :unprocessable_entity
  end

  test "show allows self bundle fetch for self sync" do
    other_device = users(:david).e2e_devices.create!(
      device_id: "dev-david-tablet",
      name: "David Tablet",
      identity_key: "david-tablet-identity"
    )
    other_device.signed_prekeys.create!(
      key_id: 9101,
      public_key: "david-tablet-spk",
      signature: "david-tablet-spk-signature",
      published_at: Time.current,
      active: true
    )
    other_device.one_time_prekeys.create!(
      key_id: 9201,
      public_key: "david-tablet-otk",
      published_at: Time.current
    )

    get user_e2e_prekey_bundle_url(user_id: "me", self_sync: true, format: :json)

    assert_response :success

    payload = JSON.parse(response.body)
    assert_equal users(:david).id, payload.dig("user", "id")
    assert_includes payload.fetch("devices").map { |device| device.fetch("device_id") }, "dev-david-tablet"
  end

  test "show returns not_found when target has no active device" do
    get user_e2e_prekey_bundle_url(user_id: users(:kevin).id, format: :json)

    assert_response :not_found
  end

  test "show returns precondition_failed when target has no signed prekey" do
    e2e_signed_prekeys(:jason_primary).update!(active: false)
    e2e_signed_prekeys(:jason_phone_primary).update!(active: false)

    get user_e2e_prekey_bundle_url(user_id: users(:jason).id, format: :json)

    assert_response :precondition_failed
  end
end
