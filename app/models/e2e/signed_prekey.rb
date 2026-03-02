class E2e::SignedPrekey < ApplicationRecord
  self.table_name = "e2e_signed_prekeys"

  belongs_to :device, class_name: "E2e::Device"

  validates :key_id, :public_key, :signature, :published_at, presence: true
  validates :key_id, uniqueness: { scope: :device_id }

  scope :active, -> { where(active: true) }
end
