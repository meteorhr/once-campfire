require "test_helper"

class Users::E2eResetControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    users(:david).update!(e2e_public_key: '{"kty":"EC"}', e2e_key_rotated_at: Time.current)
  end

  test "create revokes all devices and clears public key" do
    assert users(:david).e2e_devices.active.exists?

    post user_e2e_reset_url(format: :json)

    assert_response :success

    payload = JSON.parse(response.body)
    assert payload["reset"]

    users(:david).reload
    assert_nil users(:david).e2e_public_key
    assert_nil users(:david).e2e_key_rotated_at
    assert_not users(:david).e2e_devices.active.exists?
  end
end
