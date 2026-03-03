require "test_helper"

class QrCodeControllerTest < ActionDispatch::IntegrationTest
  test "show renders a QR code as a cacheable SVG image" do
    id = Base64.urlsafe_encode64("http://example.com")

    get qr_code_path(id)

    assert_response :success
    assert_includes response.content_type, "image/svg+xml"
    assert_includes response.body, "fill:#ffffff"
    assert_includes response.body, "fill:#000000"
    refute_includes response.body, "fill:#white"
    refute_includes response.body, "fill:#black"

    assert_equal 1.year, response.cache_control[:max_age].to_i
    assert response.cache_control[:public]
  end
end
