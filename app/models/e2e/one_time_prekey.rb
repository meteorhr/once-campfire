class E2e::OneTimePrekey < ApplicationRecord
  self.table_name = "e2e_one_time_prekeys"

  belongs_to :device, class_name: "E2e::Device"

  validates :key_id, :public_key, :published_at, presence: true
  validates :key_id, uniqueness: { scope: :device_id }

  scope :available, -> { where(consumed_at: nil) }
end
