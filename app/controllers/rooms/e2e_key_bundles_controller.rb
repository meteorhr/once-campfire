class Rooms::E2eKeyBundlesController < ApplicationController
  include RoomScoped

  before_action :ensure_direct_room

  def show
    members = @room.users.select(:id, :name, :e2e_public_key, :e2e_key_rotated_at).map do |user|
      {
        id: user.id,
        name: user.name,
        public_key: user.e2e_public_key,
        rotated_at: user.e2e_key_rotated_at&.iso8601
      }
    end

    render json: { room_id: @room.id, members: members }
  end

  def update
    key = key_bundle_params.fetch(:public_key).to_s

    if key.blank?
      render json: { error: "public_key is required" }, status: :unprocessable_entity
      return
    end

    Current.user.update!(e2e_public_key: key, e2e_key_rotated_at: Time.current)
    head :accepted
  end

  private
    def ensure_direct_room
      head :forbidden unless @room.direct?
    end

    def key_bundle_params
      params.require(:e2e).permit(:public_key)
    end
end
