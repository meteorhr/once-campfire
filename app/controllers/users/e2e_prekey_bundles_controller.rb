class Users::E2ePrekeyBundlesController < ApplicationController
  before_action :set_target_user
  before_action :ensure_other_user
  before_action :ensure_direct_room_access

  def show
    devices = @target_user.e2e_devices.active.includes(:signed_prekeys, :one_time_prekeys).order(updated_at: :desc).to_a
    return render json: { error: "No active device" }, status: :not_found if devices.empty?

    known_device_ids = parse_known_device_ids

    bundle_devices = devices.filter_map do |device|
      signed_prekey = device.active_signed_prekey
      next unless signed_prekey

      one_time_prekey = known_device_ids.include?(device.device_id) ? nil : device.claim_one_time_prekey!

      {
        id: device.id,
        device_id: device.device_id,
        name: device.name,
        identity_key: device.identity_key,
        signing_key: device.signing_key,
        signed_prekey: {
          key_id: signed_prekey.key_id,
          public_key: signed_prekey.public_key,
          signature: signed_prekey.signature,
          published_at: signed_prekey.published_at.iso8601,
          expires_at: signed_prekey.expires_at&.iso8601
        },
        one_time_prekey: one_time_prekey && {
          key_id: one_time_prekey.key_id,
          public_key: one_time_prekey.public_key,
          published_at: one_time_prekey.published_at.iso8601
        }
      }
    end

    return render json: { error: "No signed prekey" }, status: :precondition_failed if bundle_devices.empty?

    render json: {
      user: {
        id: @target_user.id,
        name: @target_user.name
      },
      devices: bundle_devices
    }
  end

  private
    def parse_known_device_ids
      return [] if params[:known_device_ids].blank?

      params[:known_device_ids].to_s.split(",").map(&:strip).reject(&:blank?).uniq
    end

    def set_target_user
      @target_user = if params[:user_id] == "me"
        Current.user
      else
        User.find(params[:user_id])
      end
    end

    def ensure_other_user
      return if self_sync_request?

      if @target_user == Current.user
        head :unprocessable_entity
        return
      end
    end

    def ensure_direct_room_access
      return if self_sync_request?

      if params[:room_id].present?
        room = Current.user.rooms.directs.find_by(id: params[:room_id])
        unless room&.users&.exists?(@target_user.id)
          head :forbidden
          return
        end
      else
        has_direct_room = Current.user.rooms.directs.includes(:users).any? do |room|
          room.users.any? { |user| user.id == @target_user.id }
        end
        unless has_direct_room
          head :forbidden
          return
        end
      end
    end

    def self_sync_request?
      @target_user == Current.user && params[:self_sync].to_s == "true"
    end
end
