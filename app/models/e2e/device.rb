class E2e::Device < ApplicationRecord
  self.table_name = "e2e_devices"

  belongs_to :user

  has_many :signed_prekeys, class_name: "E2e::SignedPrekey", dependent: :delete_all, foreign_key: :device_id
  has_many :one_time_prekeys, class_name: "E2e::OneTimePrekey", dependent: :delete_all, foreign_key: :device_id

  has_many :sent_message_envelopes, class_name: "E2e::MessageEnvelope", dependent: :delete_all, foreign_key: :sender_device_id
  has_many :received_message_envelopes, class_name: "E2e::MessageEnvelope", dependent: :delete_all, foreign_key: :recipient_device_id

  validates :device_id, :name, :identity_key, presence: true
  validates :device_id, uniqueness: { scope: :user_id }

  scope :active, -> { where(revoked_at: nil) }

  def active_signed_prekey
    signed_prekeys.active.order(published_at: :desc).first
  end

  def claim_one_time_prekey!
    with_lock do
      prekey = one_time_prekeys.available.order(:id).first
      prekey&.update!(consumed_at: Time.current)
      prekey
    end
  end
end
