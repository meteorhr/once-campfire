class Users::E2eDevicesManagementController < ApplicationController
  def index
    devices = Current.user.e2e_devices.active.order(updated_at: :desc)

    render json: {
      devices: devices.map { |device| device_payload(device) }
    }
  end

  def destroy
    device = Current.user.e2e_devices.active.find_by!(device_id: params[:id])
    device.update!(revoked_at: Time.current)

    render json: { revoked: true, device_id: device.device_id }
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private
    def device_payload(device)
      {
        id: device.id,
        device_id: device.device_id,
        name: device.name,
        identity_key: device.identity_key,
        signing_key: device.signing_key,
        created_at: device.created_at.iso8601,
        updated_at: device.updated_at.iso8601,
        last_prekey_uploaded_at: device.last_prekey_uploaded_at&.iso8601
      }
    end
end
