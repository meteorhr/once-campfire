class E2e::MessageEnvelope < ApplicationRecord
  self.table_name = "e2e_message_envelopes"

  belongs_to :room
  belongs_to :sender_device, class_name: "E2e::Device"
  belongs_to :recipient_device, class_name: "E2e::Device"

  validates :client_message_id, :algorithm, :ciphertext, presence: true
end
