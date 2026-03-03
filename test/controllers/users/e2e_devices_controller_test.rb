require "test_helper"

class Users::E2eDevicesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show returns current user's active device" do
    get user_e2e_device_url(format: :json)

    assert_response :success

    payload = JSON.parse(response.body)
    assert_equal "dev-david-phone", payload.dig("device", "device_id")
    assert_equal "david-identity-key", payload.dig("device", "identity_key")
    assert_equal 2, payload.dig("device", "one_time_prekeys_available")
  end

  test "update creates a new device with signed and one-time prekeys" do
    assert_difference -> { E2e::Device.count }, +1 do
      assert_difference -> { E2e::SignedPrekey.count }, +1 do
        assert_difference -> { E2e::OneTimePrekey.count }, +2 do
          put user_e2e_device_url(format: :json), params: {
            e2e_device: {
              device_id: "dev-david-tablet",
              name: "David Tablet",
              identity_key: "identity-tablet",
              signed_prekey: {
                key_id: 9001,
                public_key: "spk-tablet",
                signature: "spk-signature"
              },
              one_time_prekeys: [
                { key_id: 9101, public_key: "otk-1" },
                { key_id: 9102, public_key: "otk-2" }
              ]
            }
          }
        end
      end
    end

    assert_response :created

    device = E2e::Device.find_by!(device_id: "dev-david-tablet")
    assert_equal users(:david), device.user
    assert_equal "David Tablet", device.name
    assert_equal "identity-tablet", device.identity_key
    assert_equal 2, device.one_time_prekeys.available.count
  end

  test "update rotates signed prekey and deactivates previous key" do
    put user_e2e_device_url(format: :json), params: {
      e2e_device: {
        device_id: "dev-david-phone",
        name: "David Phone",
        identity_key: "david-identity-key",
        signed_prekey: {
          key_id: 1002,
          public_key: "david-signed-prekey-2",
          signature: "david-signature-2"
        }
      }
    }

    assert_response :ok

    device = e2e_devices(:david_phone)
    assert_equal 1, device.signed_prekeys.active.count
    assert_equal 1002, device.active_signed_prekey.key_id
    assert_not E2e::SignedPrekey.find_by(device:, key_id: 1001).active?
  end

  test "update creates a device with ECDSA signing key" do
    put user_e2e_device_url(format: :json), params: {
      e2e_device: {
        device_id: "dev-david-signed",
        name: "David Signed Device",
        identity_key: "identity-signed",
        signing_key: '{"kty":"EC","crv":"P-256","x":"abc","y":"def"}',
        signed_prekey: {
          key_id: 9501,
          public_key: "spk-signed",
          signature: "ecdsa-signature-here"
        }
      }
    }

    assert_response :created

    device = E2e::Device.find_by!(device_id: "dev-david-signed")
    assert_equal '{"kty":"EC","crv":"P-256","x":"abc","y":"def"}', device.signing_key

    payload = JSON.parse(response.body)
    assert_equal '{"kty":"EC","crv":"P-256","x":"abc","y":"def"}', payload.dig("device", "signing_key")
  end

  test "update rejects invalid payload" do
    put user_e2e_device_url(format: :json), params: {
      e2e_device: {
        device_id: "",
        name: "",
        identity_key: ""
      }
    }

    assert_response :unprocessable_entity
  end
end
