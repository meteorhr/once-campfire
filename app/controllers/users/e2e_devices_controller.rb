class Users::E2eDevicesController < ApplicationController
  def show
    device = Current.user.e2e_devices.active.order(updated_at: :desc).first

    if device
      render json: device_payload(device)
    else
      head :no_content
    end
  end

  def update
    created = false

    device = Current.user.e2e_devices.find_or_initialize_by(device_id: e2e_device_params.fetch(:device_id))

    created = device.new_record?

    E2e::Device.transaction do
      device.assign_attributes(
        name: e2e_device_params.fetch(:name),
        identity_key: e2e_device_params.fetch(:identity_key),
        last_prekey_uploaded_at: Time.current,
        revoked_at: nil
      )
      device.save!

      upsert_signed_prekey!(device, signed_prekey_params)
      upsert_one_time_prekeys!(device, one_time_prekeys_params)
    end

    render json: device_payload(device.reload), status: (created ? :created : :ok)
  rescue ActionController::ParameterMissing, KeyError, ActiveRecord::RecordInvalid
    render json: { error: "Invalid e2e_device payload" }, status: :unprocessable_entity
  end

  private
    def e2e_device_params
      params.require(:e2e_device).permit(
        :device_id,
        :name,
        :identity_key,
        signed_prekey: [ :key_id, :public_key, :signature, :expires_at ],
        one_time_prekeys: [ :key_id, :public_key ]
      )
    end

    def signed_prekey_params
      e2e_device_params.fetch(:signed_prekey)
    end

    def one_time_prekeys_params
      Array(e2e_device_params[:one_time_prekeys]).map(&:to_h)
    end

    def upsert_signed_prekey!(device, params)
      signed_prekey = device.signed_prekeys.find_or_initialize_by(key_id: params.fetch(:key_id))
      signed_prekey.assign_attributes(
        public_key: params.fetch(:public_key),
        signature: params.fetch(:signature),
        expires_at: params[:expires_at],
        published_at: Time.current,
        active: true
      )
      signed_prekey.save!

      device.signed_prekeys.where.not(id: signed_prekey.id).update_all(active: false, updated_at: Time.current)
    end

    def upsert_one_time_prekeys!(device, prekeys)
      return if prekeys.empty?

      prekeys.each do |params|
        next if params["key_id"].blank? || params["public_key"].blank?

        device.one_time_prekeys.find_or_create_by!(key_id: params["key_id"]) do |prekey|
          prekey.public_key = params["public_key"]
          prekey.published_at = Time.current
        end
      end
    end

    def device_payload(device)
      {
        device: {
          id: device.id,
          device_id: device.device_id,
          name: device.name,
          identity_key: device.identity_key,
          signed_prekey: signed_prekey_payload(device.active_signed_prekey),
          one_time_prekeys_available: device.one_time_prekeys.available.count,
          updated_at: device.updated_at.iso8601
        }
      }
    end

    def signed_prekey_payload(prekey)
      return nil unless prekey

      {
        key_id: prekey.key_id,
        public_key: prekey.public_key,
        signature: prekey.signature,
        published_at: prekey.published_at.iso8601,
        expires_at: prekey.expires_at&.iso8601
      }
    end
end
