require "test_helper"

class Rooms::E2eKeyBundlesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show returns the direct room members with key bundles" do
    users(:david).update!(e2e_public_key: '{"kty":"EC","crv":"P-256","x":"a","y":"b"}')
    users(:jason).update!(e2e_public_key: '{"kty":"EC","crv":"P-256","x":"c","y":"d"}')

    get room_e2e_key_bundle_url(rooms(:david_and_jason), format: :json)

    assert_response :success

    parsed = JSON.parse(response.body)
    assert_equal rooms(:david_and_jason).id, parsed["room_id"]
    assert_equal [ users(:david).id, users(:jason).id ].sort, parsed["members"].map { |member| member["id"] }.sort
  end

  test "show is forbidden for non-direct rooms" do
    get room_e2e_key_bundle_url(rooms(:watercooler), format: :json)

    assert_response :forbidden
  end

  test "update stores the current user key" do
    put room_e2e_key_bundle_url(rooms(:david_and_jason), format: :json), params: {
      e2e: {
        public_key: '{"kty":"EC","crv":"P-256","x":"abc","y":"def"}'
      }
    }

    assert_response :accepted

    assert_equal '{"kty":"EC","crv":"P-256","x":"abc","y":"def"}', users(:david).reload.e2e_public_key
    assert users(:david).e2e_key_rotated_at.present?
  end

  test "update requires a public key" do
    put room_e2e_key_bundle_url(rooms(:david_and_jason), format: :json), params: {
      e2e: { public_key: "" }
    }

    assert_response :unprocessable_entity
  end
end
