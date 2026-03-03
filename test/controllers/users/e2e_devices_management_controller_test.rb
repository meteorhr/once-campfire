require "test_helper"

class Users::E2eDevicesManagementControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "index lists all active devices" do
    get user_e2e_devices_management_index_url(format: :json)

    assert_response :success

    payload = JSON.parse(response.body)
    assert_equal 1, payload["devices"].length
    assert_equal "dev-david-phone", payload["devices"].first["device_id"]
  end

  test "destroy revokes a device" do
    device = e2e_devices(:david_phone)

    delete user_e2e_devices_management_url(device.device_id, format: :json)

    assert_response :success

    payload = JSON.parse(response.body)
    assert payload["revoked"]

    device.reload
    assert device.revoked_at.present?
  end

  test "destroy returns not_found for unknown device" do
    delete user_e2e_devices_management_url("nonexistent-device", format: :json)

    assert_response :not_found
  end
end
