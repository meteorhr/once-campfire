class Users::E2eResetController < ApplicationController
  def create
    E2e::Device.transaction do
      Current.user.e2e_devices.active.update_all(revoked_at: Time.current)
      Current.user.update!(e2e_public_key: nil, e2e_key_rotated_at: nil)
    end

    render json: { reset: true }
  end
end
